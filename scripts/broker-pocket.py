#!/usr/bin/env python3
"""broker-pocket.py — pocket reference of a second-engine broker (docs/09-second-engine-broker.md).

Three guarantees: every run is reconstructable (hash-chained log + 0600 run file,
checked by `replay`); the data class is gated BEFORE the engine starts (fail-closed);
no run leaves anything behind (process group, scrubbed env, lane removed, timeout kill).
Teaching code, not a product: no sandbox profiles, no quota caps, no fan-out, no retention.
Usage: run --engine stub --class public "hello" | replay | selftest   (Python >= 3.9, stdlib)
"""
import argparse, contextlib, datetime, fcntl, hashlib, json, os, pwd, secrets, shutil
import signal, stat, subprocess, sys, tempfile, threading, time

CLASSES = ("public", "internal", "confidential")
SAFE_PATH = "~/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"  # never the caller's PATH
EXIT_OK, EXIT_BLOCKED, EXIT_TIMEOUT, EXIT_INTEGRITY, EXIT_REJECTED, EXIT_ENGINE = 0, 3, 4, 5, 6, 7

# Stand-in engine so `selftest` never needs a real CLI. Reads the prompt on stdin.
STUB = (
    "import os,subprocess,sys,time\n"
    "p=open(sys.argv[1]).read() if len(sys.argv)>1 else sys.stdin.read()\n"
    "if p.startswith('ENV?'):\n"
    "    print('\\n'.join(k+'='+v for k,v in sorted(os.environ.items())))\n"
    "elif p.startswith('BG'):\n"
    "    c=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'],stdout=-3,stderr=-3)\n"
    "    print('grandchild', c.pid)\n"
    "elif p.startswith('SLEEP'):\n"
    "    c=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'])\n"
    "    print('grandchild', c.pid, flush=True); time.sleep(float(p.split()[1]))\n"
    "else:\n"
    "    print('echo: '+p)\n"
)

# Engine table. The prompt goes over stdin or a 0600 file in the lane, never argv (`ps` shows argv).
# The three real entries are ILLUSTRATIVE: check the flags against `<cli> --help` of the
# version you installed, and give each engine a real sandbox (docs/09, lessons 1-3).
ENGINES = {
    "codex": {"binary": "codex", "argv": ["exec", "--sandbox", "read-only", "--skip-git-repo-check", "-"]},
    "vibe": {"binary": "vibe", "argv": ["-p", "--output", "text", "--enabled-tools", "__none__"]},
    "grok": {"binary": "grok", "argv": ["--prompt-file", "{prompt_file}"]},
    "stub": {"binary": sys.executable, "argv": ["-c", STUB]},
}

class Paths:
    """Every location the broker touches, derived from ONE home directory."""
    def __init__(self, home):
        self.home = home
        self.state = os.path.join(home, ".local", "state", "fleet-broker")
        self.runs = os.path.join(self.state, "runs")
        self.lanes = os.path.join(self.state, "lanes")
        self.taxonomy = os.path.join(home, ".config", "fleet-broker", "taxonomy.json")

    @classmethod
    def real(cls):
        # HOME from the password database, not $HOME: the caller's environment
        # must not be able to move the log or the taxonomy somewhere convenient.
        return cls(pwd.getpwuid(os.getuid()).pw_dir)

def utcnow():
    return datetime.datetime.now(datetime.timezone.utc)

def new_run_id():
    return utcnow().strftime("%Y%m%dT%H%M%SZ") + "-" + secrets.token_hex(3)

def sha256(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()

def canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)

def mkdir(path):
    os.makedirs(path, mode=0o700, exist_ok=True)
    return path

# ---------------------------------------------------------------- the log --
class ChainLog:
    """Append-only monthly JSONL; every event carries prev_sha256 and its own sha256."""
    _thread_lock = threading.Lock()  # flock does not exclude threads sharing one file description

    def __init__(self, paths):
        self.p = paths

    def files(self):
        names = sorted(os.listdir(self.p.state)) if os.path.isdir(self.p.state) else []
        return [os.path.join(self.p.state, n) for n in names if n.startswith("broker-") and n.endswith(".jsonl")]

    def _last(self):
        for path in reversed(self.files()):
            with open(path, "rb") as fh:
                lines = [l for l in fh.read().splitlines() if l.strip()]
            if lines:
                return json.loads(lines[-1])["sha256"], os.path.basename(path)
        return None, None

    def append(self, event, **fields):
        with self._thread_lock, open(os.path.join(mkdir(self.p.state), ".chain.lock"), "a") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            now = utcnow()
            # The file is chosen PER EVENT, under the lock: a path picked at open time
            # breaks the chain when two processes straddle a month boundary.
            path = os.path.join(self.p.state, now.strftime("broker-%Y-%m.jsonl"))
            prev, prev_file = self._last()
            obj = dict(fields, event=event, ts=now.isoformat(timespec="seconds"), prev_sha256=prev)
            if prev_file and prev_file != os.path.basename(path):
                obj["prev_file"] = prev_file
            obj["sha256"] = sha256(canonical(obj))
            with os.fdopen(os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600), "a") as fh:
                fh.write(canonical(obj) + "\n")
                fh.flush()
                os.fsync(fh.fileno())

# ------------------------------------------------------------ the gates --
class Rejected(Exception):
    pass

def resolve_binary(spec, home):
    """Find the engine on a FIXED path, resolve symlinks, check owner and mode."""
    name = spec["binary"]
    found = name if os.path.isabs(name) else shutil.which(name, path=SAFE_PATH.replace("~", home))
    if not found:
        raise Rejected("binary not found on the fixed search path: %s" % name)
    real = os.path.realpath(found)
    st = os.stat(real)
    if st.st_uid not in (os.getuid(), 0):
        raise Rejected("binary owned by uid %d, not by us or root: %s" % (st.st_uid, real))
    if st.st_mode & stat.S_IWOTH or os.stat(os.path.dirname(real)).st_mode & stat.S_IWOTH:
        raise Rejected("binary or its directory is world-writable: %s" % real)
    return found, real

def load_taxonomy(paths):
    """(state, data). Only state 'ok' carries data; anything else blocks."""
    try:
        st = os.lstat(paths.taxonomy)  # regular file, ours or root's, not group/world-writable
        if (not stat.S_ISREG(st.st_mode) or st.st_uid not in (os.getuid(), 0)
                or st.st_mode & (stat.S_IWGRP | stat.S_IWOTH)):
            return "unsafe", {}
        with open(paths.taxonomy, encoding="utf-8") as fh:
            data = json.load(fh)
        return ("ok", data) if isinstance(data, dict) else ("invalid", {})
    except FileNotFoundError:
        return "missing", {}
    except (OSError, ValueError):
        return "invalid", {}

def engine_is_in_house(engine, paths=None):
    """True ONLY for the exact answer "in-house". Missing, broken, true, 1, "yes" -> False."""
    state, data = load_taxonomy(paths or Paths.real())
    return state == "ok" and data.get(engine) == "in-house"

def class_gate(engine, klass, paths):
    if klass == "public":
        return None
    state, _ = load_taxonomy(paths)
    if state != "ok":
        return "class %s needs a taxonomy file; %s is %s (fail-closed)" % (klass, paths.taxonomy, state)
    if klass == "confidential" and not engine_is_in_house(engine, paths):
        return "engine %r is not listed as in-house by contract; confidential blocked" % engine
    return None

def scrubbed_env(home, lane):
    env = {"PATH": SAFE_PATH.replace("~", home), "HOME": home, "TMPDIR": lane}
    env.update({k: os.environ[k] for k in ("LANG", "TERM") if k in os.environ})  # nothing else
    return env

def kill_group(proc):
    """SIGTERM the whole group, 2 s grace, then SIGKILL whatever is left (grandchildren too)."""
    with contextlib.suppress(ProcessLookupError, PermissionError):  # group gone / only zombies
        os.killpg(proc.pid, signal.SIGTERM)
        with contextlib.suppress(subprocess.TimeoutExpired):
            proc.wait(timeout=2)
        os.killpg(proc.pid, signal.SIGKILL)

# -------------------------------------------------------------- one run --
def run_one(paths, engine, klass, prompt, timeout=600, engines=None):
    log, run_id, t0 = ChainLog(paths), new_run_id(), time.time()
    base = {"run_id": run_id, "engine": engine, "class": klass}
    log.append("run.started", prompt_sha256=sha256(prompt), caller_ppid=os.getppid(), **base)
    rec = dict(base, prompt=prompt, prompt_sha256=sha256(prompt), started=utcnow().isoformat())

    def finish(stop_reason, code, output=None, diagnostic=None):
        rec.update(stop_reason=stop_reason, exit_code=code, output=output, diagnostic=diagnostic,
                   output_sha256=None if output is None else sha256(output),
                   finished=utcnow().isoformat(), wall_s=round(time.time() - t0, 3))
        run_file = "%s.%s.json" % (run_id, klass)
        body = json.dumps(rec, ensure_ascii=False, indent=1)
        fd = os.open(os.path.join(mkdir(paths.runs), run_file), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(body)
            fh.flush()
            os.fsync(fh.fileno())  # the record is durable before the log says "finished"
        log.append("run.finished", stop_reason=stop_reason, exit_code=code, output_sha256=rec["output_sha256"],
                   run_file=run_file, run_file_sha256=sha256(body), wall_s=rec["wall_s"], **base)
        keys = ("run_id", "engine", "class", "stop_reason", "exit_code", "output", "diagnostic", "wall_s")
        return code, {k: rec[k] for k in keys}

    blocked = class_gate(engine, klass, paths)  # before anything is spawned
    if blocked:
        return finish("governance-blocked", EXIT_BLOCKED, diagnostic=blocked)
    spec = (engines or ENGINES)[engine]
    try:
        found, real = resolve_binary(spec, paths.home)
    except (Rejected, OSError) as exc:
        return finish("binary-rejected", EXIT_REJECTED, diagnostic=str(exc))
    lane = tempfile.mkdtemp(prefix=run_id + "-", dir=mkdir(paths.lanes))
    argv, proc = [real] + spec["argv"], None  # execute what was checked, not what the name points to now
    try:
        if any("{prompt_file}" in a for a in argv):  # CLIs that only read a file get one in the lane
            pf = os.path.join(lane, "prompt.txt")
            with os.fdopen(os.open(pf, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w", encoding="utf-8") as fh:
                fh.write(prompt)
            argv = [a.replace("{prompt_file}", pf) for a in argv]
        proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, cwd=lane, env=scrubbed_env(paths.home, lane),
                                start_new_session=True)
        log.append("run.spawned", pid=proc.pid, binary_realpath=real, **base)
        try:
            out, err = proc.communicate(prompt.encode("utf-8"), timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt) as exc:
            kill_group(proc)
            out, err = proc.communicate()
            timed_out = isinstance(exc, subprocess.TimeoutExpired)
            return finish("timeout" if timed_out else "cancelled", EXIT_TIMEOUT if timed_out else 130,
                          out.decode("utf-8", "replace"), "engine process group killed")
        if proc.returncode != 0:
            return finish("engine-error", EXIT_ENGINE, out.decode("utf-8", "replace"),
                          err.decode("utf-8", "replace")[-2000:])
        return finish("completed", EXIT_OK, out.decode("utf-8", "replace"))
    except OSError as exc:
        return finish("engine-error", EXIT_ENGINE, diagnostic="start failed: %s" % exc)
    finally:
        if proc is not None:  # every run, not only on timeout: background children die with the group
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.killpg(proc.pid, signal.SIGKILL)
        shutil.rmtree(lane, ignore_errors=True)
        if os.path.exists(lane):
            print("warning: lane not removed: %s" % lane, file=sys.stderr)

# --------------------------------------------------------------- replay --
def replay(paths):
    prev, events, problems = None, {}, []
    for path in ChainLog(paths).files():
        with open(path, encoding="utf-8") as fh:
            for no, raw in enumerate(fh, 1):
                if not raw.strip():
                    continue
                fail = {"integrity": "FAIL", "at": "%s:%d" % (os.path.basename(path), no)}
                try:
                    obj = json.loads(raw)
                    claimed = obj.pop("sha256")
                    event, run_id = str(obj["event"]), obj.get("run_id")
                except (ValueError, KeyError, TypeError, AttributeError):
                    return dict(fail, reason="unparseable line")
                if sha256(canonical(obj)) != claimed:
                    return dict(fail, reason="line hash mismatch")
                if obj.get("prev_sha256") != prev:
                    return dict(fail, reason="chain broken (prev_sha256)")
                prev = claimed
                events.setdefault(run_id, {})[event] = obj
    for run_id, ev in events.items():
        start, end = ev.get("run.started"), ev.get("run.finished")
        try:
            path = os.path.join(paths.runs, end["run_file"])
            with open(path, encoding="utf-8") as fh:
                body = fh.read()
            rec = json.loads(body)
            ok = (start and sha256(body) == end["run_file_sha256"]  # the whole record, every field
                  and sha256(rec["prompt"]) == start["prompt_sha256"])
        except (TypeError, KeyError, OSError, ValueError, AttributeError):
            problems.append("%s: run incomplete or run file unreadable" % run_id)
            continue
        if not ok:
            problems.append("%s: run file does not match the logged hashes" % run_id)
        if os.stat(path).st_mode & 0o077:
            problems.append("%s: run file readable or writable by others" % run_id)
    return {"integrity": "FAIL" if problems else "OK", "runs": len(events), "problems": problems}

# ------------------------------------------------------------- selftest --
def selftest():
    real_state, results, saved_env = Paths.real().state, [], dict(os.environ)
    existed_before = os.path.exists(real_state)

    def check(name, ok, detail=""):
        results.append(bool(ok))
        print("%s  %-44s %s" % ("PASS" if ok else "FAIL", name, detail or ""))

    def taxonomy(data, mode=0o600):
        if os.path.exists(paths.taxonomy):
            os.unlink(paths.taxonomy)
        mkdir(os.path.dirname(paths.taxonomy))
        with os.fdopen(os.open(paths.taxonomy, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as fh:
            json.dump(data, fh)
        os.chmod(paths.taxonomy, mode)

    with tempfile.TemporaryDirectory(prefix="broker-pocket-selftest-") as home:
        os.environ.update(HOME=home, XDG_STATE_HOME=os.path.join(home, ".local", "state"))
        paths = Paths(home)  # built in-process: no flag or env var relocates the real log
        try:
            code, out = run_one(paths, "stub", "public", "hello")
            first = out["run_id"]
            check("run public with stub", code == 0 and (out["output"] or "").strip() == "echo: hello",
                  out["diagnostic"] or out["stop_reason"])
            if code == EXIT_REJECTED:  # the allowlist working, not a bug: nothing else can run
                print("selftest stopped: run it with a Python interpreter owned by you or root")
                return 1
            code, out = run_one(paths, "stub", "confidential", "plan")
            check("confidential without taxonomy blocks", code == EXIT_BLOCKED, out["diagnostic"])
            check("internal without taxonomy blocks", run_one(paths, "stub", "internal", "n")[0] == EXIT_BLOCKED)
            for data, mode, want, name in (({"stub": True}, 0o600, EXIT_BLOCKED, "truthy-but-not-'in-house' blocks"),
                                           ({"stub": "in-house"}, 0o666, EXIT_BLOCKED, "world-writable taxonomy blocks"),
                                           ({"stub": "in-house"}, 0o600, EXIT_OK, "confidential with in-house runs")):
                taxonomy(data, mode)
                check(name, run_one(paths, "stub", "confidential", "plan")[0] == want)
            bait = os.environ["POCKET_BAIT"] = "bait-" + secrets.token_hex(8)
            code, out = run_one(paths, "stub", "public", "ENV?")
            positive = "HOME=%s" % home in out["output"]  # positive control: the stub really dumped its env
            check("env scrub: bait absent, HOME present", code == 0 and positive and bait not in out["output"])
            code, out = run_one(paths, "stub", "public", "SLEEP 30", timeout=2)
            gpid = int(out["output"].split()[1]) if out["output"].startswith("grandchild") else None
            check("timeout returns exit 4", code == EXIT_TIMEOUT, out["stop_reason"])
            # Without a group kill the grandchild keeps the pipe open and the run hangs until it
            # exits on its own -- "gone" alone would then look green. Check the wall clock too.
            check("timeout kills the grandchild too", gpid and _gone(gpid) and out["wall_s"] < 10,
                  "pid %s, wall %.1fs" % (gpid, out["wall_s"]))
            code, out = run_one(paths, "stub", "public", "BG")
            gpid = int(out["output"].split()[1]) if out["output"].startswith("grandchild") else None
            check("normal exit kills background children", code == 0 and gpid and _gone(gpid), "pid %s" % gpid)
            fake = os.path.join(home, "fake-engine")
            spec = {"fake": {"binary": fake, "argv": []}}
            with open(fake, "w") as fh:
                fh.write("#!/bin/sh\necho fake\n")
            os.chmod(fake, 0o777)
            code, out = run_one(paths, "fake", "public", "x", engines=spec)
            check("world-writable engine binary -> exit 6", code == EXIT_REJECTED, out["diagnostic"])
            os.chmod(fake, 0o755)
            code, out = run_one(paths, "fake", "public", "x", engines=spec)
            check("same binary 0755 runs (positive control)", code == 0 and out["output"].strip() == "fake")
            spec = {"stub-file": dict(ENGINES["stub"], argv=ENGINES["stub"]["argv"] + ["{prompt_file}"])}
            code, out = run_one(paths, "stub-file", "public", "via file", engines=spec)
            check("prompt file read, lanes left empty", code == 0 and out["output"].strip() == "echo: via file"
                  and not os.listdir(paths.lanes), "lanes: %s" % os.listdir(paths.lanes))
            check("replay OK", replay(paths)["integrity"] == "OK")
            run_file = os.path.join(paths.runs, first + ".public.json")
            _tamper(run_file, '"output": "echo: hello', '"output": "echo: HELLO')
            check("tampered run file -> replay FAIL", replay(paths)["problems"])
            _tamper(run_file, '"output": "echo: HELLO', '"output": "echo: hello')  # restore
            os.chmod(run_file, 0o644)
            check("run file mode 0644 -> replay FAIL", replay(paths)["problems"])
            os.chmod(run_file, 0o600)  # restore, then break the log
            _tamper(ChainLog(paths).files()[-1], '"class":"', '"class":"x', line=1)
            rep = replay(paths)
            check("tampered log line -> FAIL with line number", rep.get("at", "").endswith(":2"), rep.get("at"))
        finally:
            os.environ.clear()
            os.environ.update(saved_env)
    check("real state untouched", os.path.exists(real_state) == existed_before, real_state)
    print("selftest: %d/%d passed" % (sum(results), len(results)))
    return 0 if all(results) else 1

def _tamper(path, old, new, line=None):
    with open(path, encoding="utf-8") as fh:
        lines = fh.readlines()
    for i in [line] if line is not None else range(len(lines)):
        lines[i] = lines[i].replace(old, new, 1)
    with open(path, "w", encoding="utf-8") as fh:
        fh.writelines(lines)

def _gone(pid):
    for _ in range(30):  # 3 s
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        time.sleep(0.1)
    return False

# ------------------------------------------------------------------ CLI --
def main(argv=None):
    ap = argparse.ArgumentParser(description="Pocket reference of a second-engine broker.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", help="start one engine for one prompt")
    r.add_argument("--engine", required=True, choices=sorted(ENGINES))
    r.add_argument("--class", dest="klass", required=True, choices=CLASSES)
    r.add_argument("--timeout", type=int, default=600)
    r.add_argument("prompt")
    sub.add_parser("replay", help="verify the hash chain and every run file")
    sub.add_parser("selftest", help="stub-only checks in a throwaway home")
    args = ap.parse_args(argv)
    if args.cmd == "selftest":
        return selftest()
    if args.cmd == "replay":
        rep = replay(Paths.real())
        print(json.dumps(rep, indent=1))
        return EXIT_OK if rep["integrity"] == "OK" else EXIT_INTEGRITY
    if not 1 <= args.timeout <= 7200:
        ap.error("--timeout must be 1..7200")
    code, out = run_one(Paths.real(), args.engine, args.klass, args.prompt, args.timeout)
    print(json.dumps(out, ensure_ascii=False))
    return code

if __name__ == "__main__":
    sys.exit(main())
