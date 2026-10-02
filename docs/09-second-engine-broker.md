# 09 — A Second-Engine Broker

Chapter 08 says the check has to be independent of the thing it checks. Once a
fleet takes that seriously, it runs into a limit: three Claude instances
reviewing each other are three *personas* of one model family. They can share a
blind spot. Real independence means a **second vendor's model** — another
agent CLI on the same machine, asked the same question.

That second engine is also a new attack surface. It reads files, runs tools,
gets its own credentials, and is called from scripts at 3 a.m. Without a single
entry point you get a dozen ad-hoc wrappers, each with its own idea of what the
engine may see. The fix is a small **broker**: one command that starts a
second engine and keeps three promises about every run.

The primary agent CLI stays the **conductor** — it decides, synthesizes, and
answers. The broker is the **hand**, never the head.

## Why a second engine at all

| Same family, different persona            | Different vendor                              |
| ----------------------------------------- | --------------------------------------------- |
| shares training data and search habits    | different index coverage, different habits    |
| errors correlate — they agree when wrong  | errors are partly independent                 |
| cheap, already wired                      | needs a broker, a gate, a log                 |

We use public, off-the-shelf CLIs as second engines (Codex CLI, Mistral Vibe,
Grok CLI). Which one is "best" is not the point. The point is that they **fail
differently**, and that difference is what a check needs.

> **Two engines that agree are not evidence.** In one measured research
> question, two engines agreed and shared the same gap. A third engine found
> two relevant documents that neither of the first two had seen.

## One command, three guarantees

```
broker run --engine <name> --class <public|internal|confidential> "<prompt>"
```

| Guarantee | Mechanism | How you check it |
| --- | --- | --- |
| **1. Every run is reconstructable** | append-only JSONL log, each event carries `prev_sha256` + its own `sha256`; one run file per run (`runs/<run_id>.<class>.json`, mode 0600, fsynced before the log says "finished") | `broker replay` re-hashes every line, walks the chain, re-hashes every **whole** run file against the logged hash and checks its mode |
| **2. The data class is gated before the start** | the broker looks the engine up in a taxonomy file *before* spawning anything; no answer = no run | the block itself is logged (`run.started` → `run.finished: governance-blocked`, no `run.spawned`) |
| **3. No run leaves anything behind** | own process group, killed after **every** run (not only on timeout), scrubbed environment, per-run lane directory that is deleted, engine-specific sandbox | selftest: bait variable absent, grandchildren dead, lanes empty |

### Guarantee 1 — the log

| Event | Key fields (never the prompt or output text) |
| --- | --- |
| `run.started` | `run_id`, `engine`, `class`, `prompt_sha256`, caller PID |
| `run.spawned` | `pid`, resolved binary path |
| `run.finished` | `stop_reason`, `exit_code`, `output_sha256`, `run_file`, `run_file_sha256`, `wall_s` |

`run_id` is `UTC YYYYMMDDTHHMMSSZ-<6 hex>`: sortable and unique enough. The
log holds **hashes only**. The text lives in the 0600 run file. That split
lets you age the text out later without breaking the proof (see Retention).

What the chain detects: an edited, reordered, deleted or half-written line
anywhere **before** the last entry. What it does **not** detect: a cut-off
**tail** (the last runs plus their files removed leaves a valid prefix), or the
same user rewriting everything. Both need an anchor outside the machine. Copy
the latest hash somewhere else on a schedule, e.g. into a commit on another
node. Say so in your docs.

### Guarantee 2 — the data-class gate

| Class | Runs when | Typical content |
| --- | --- | --- |
| `public` | always | published material, generic questions |
| `internal` | a taxonomy file exists and is valid | your own notes, non-sensitive business context |
| `confidential` | the taxonomy lists **this engine** as `"in-house"` | client material, unpublished work, personal data |

The taxonomy is one small file (`~/.config/fleet-broker/taxonomy.json`,
`{"engine": "in-house" | "external"}`). Rules:

- **Missing, unreadable, malformed, symlinked or group/world-writable → block.**
  Fail-closed is the whole point.
- **Only the exact positive answer counts.** `true`, `1`, `"yes"` are not
  `"in-house"`. See lesson 3 for why "anything that isn't a no" is a trap.
- If you search several candidate locations, the **first existing** one wins,
  and a defect there **blocks**. It does not fall through to the next
  candidate. A ranking that keeps looking past a broken entry gives an
  attacker a way to pick the answer.
- `--class` is self-declared by the caller. The broker cannot stop a lie. It
  makes the lie **attributable**: caller PID, class and taxonomy are logged.

### Guarantee 3 — no leftovers

| Leak path | Guard |
| --- | --- |
| parent secrets in env (`*_TOKEN`, cloud keys) | new env from an allowlist: fixed `PATH`, `HOME` from the password database, `LANG`, `TERM`, `TMPDIR` = lane |
| prompt visible in `ps` | prompt via stdin or a 0600 file inside the lane, never argv |
| orphaned grandchildren | `start_new_session=True`; on timeout `killpg` SIGTERM → 2 s → SIGKILL; after a **normal** exit `killpg` SIGKILL too (a detached background child would survive otherwise) |
| binary swapped between check and start | execute the checked `realpath`, not the name it was found under |
| temp files | per-run lane directory, removed in `finally` |
| engine reads your home | per-engine sandbox, proven with a bait file (lessons 1, 2, 5) |

## The contract is the boundary, not the vendor

Which engine may see confidential material is decided by **one question:
is there a contract that binds the vendor to your terms?** For example, an
enterprise or business agreement with data-processing terms and no training on
your inputs. With such a contract, a third-party engine is "in-house by
contract", the same as your primary CLI. Without one, it is external, however
good the model is.

| Often confused with the boundary | What it actually settles |
| --- | --- |
| hosting region (e.g. EU hosting) | **jurisdiction**: which law applies. Not confidentiality |
| vendor reputation / size | nothing contractual |
| "we pay for it" | a consumer subscription is not a data-processing agreement |
| a local model | in-house by construction (no third party involved) |

The taxonomy file is where that decision lives. A human makes it, it is
versioned, and the broker only reads it.

## Fan-out: one finds, one checks, one proves

`fanout` sends the **same prompt** to several engines at once. Each vote is a
full single run: own `run_id`, own gate check, own log events, own run file.
The result lists `runs[]`, plus `blocked[]`, `missing[]` and `failed[]`, so an
engine is never silently dropped. A `min-ok` threshold counts **distinct
vendors** with a completed run. Below it the call fails, but every raw answer
is still returned. Identical outputs are grouped mechanically.

**Synthesis happens at the conductor, never inside the broker.** The broker
does not judge, rank or summarize. The conductor (or a separate sub-agent)
reads the votes, names agreement, contradiction and gaps per engine, and writes
the answer. Class-A claims then go through the verifier from chapter 08.

For broad research questions (literature and standards searches, state of the art, market scans) we
give the engines **different roles** instead of the same question three times:

| Role | Strength used | Rule |
| --- | --- | --- |
| **one finds** | breadth: open web, other index coverage | collects candidates, never has the last word |
| **one checks** | depth: reads sources, **contradicts explicitly** (also you) | checks every finding against the source |
| **one proves** | primary sources (registries, original papers) | every identifier and number; **stop at 30 % failure** (chapter 08) |

Why the split, measured on our own runs (one run, small sample; it does not
rank any product): **the breadth engine got 3.1 % of identifiers wrong, but up to 28.6 % of its content descriptions in one measured run.**
Good at finding, weak at characterizing. The checking engine caught
exactly those errors. The roles follow from the error profile, not from
preference.

## What we learned the hard way (measured)

Each of these was measured with a bait file, a fake binary or a broken input,
not taken from documentation.

1. **A "read-only" sandbox can read the whole disk.** Read-only means "writes
   nothing", not "reads only the lane". A bait file in the home root was read.
   Use a granular profile: home denied, toolchain and working dir readable.
2. **"Auto-approve" means a full user shell.** One CLI with auto-approve
   created files and read `$HOME`. Disable its tools explicitly and wrap it in
   an allowlist sandbox.
3. **rc 1 is bash's generic error, so "rc 1 = allowed" is fail-open.** A
   taxonomy script with `set -e` and a missing dependency would have *allowed*
   confidential runs. Accept only an explicit, exact positive answer (a
   specific stdout token or value), never an exit code that errors also produce.
4. **The caller's `$HOME` and `PATH` are not trustworthy.** Both could move the
   log, the sandbox boundary, or the `bash` that runs the gate (a fake `bash`
   opened the gate). Take `HOME` from the password database and call system
   tools by absolute path.
5. **Every control needs a positive control.** A bait test passed as "sealed"
   when the engine had simply not read anything. Now the engine must read its
   *own* lane file, or "did not read the bait" counts for nothing.
6. **An allowlist built from your own filesystem is a guess about other
   machines.** Paths derived on `worker-a` silently fell out of the filter on
   `hub`, which keeps its clones elsewhere. Keep per-machine layout as reviewed
   code and show what the filter rejected *before* a run.
7. **Green on one machine proves nothing about paths only another machine
   has.** A directory that one CLI reads at startup existed only on
   `worker-b`. Run the selftest on every machine. Every new allow rule gets a
   probe: readable where intended, blocked right next to it.
8. **Unpinned `npx -y …@latest` MCP servers in a CLI's user config run on
   every start.** That is a supply-chain door you never reviewed. Start engines
   with user config ignored and ephemeral sessions, and pin what you keep.
9. **`flock` does not lock between threads that share one file
   description.** Four parallel votes interleaved the hash chain. Add a
   thread lock on top of the file lock.
10. **A month rollover breaks the hash chain if the log path is chosen at
    open time.** Two processes straddling midnight UTC wrote to different
    files. Choose the path **per event, under the lock**, and link the first
    line of a month to the last line of the previous one.
11. **Engines never come from the caller's `PATH`.** Resolve them from a fixed
    allowlist, follow the `realpath`, and require owner ∈ {you, root} and not
    world-writable, for the launcher **and** its interpreter. An interpreter
    installed by a different user account gets rejected. That is correct.

## Retention

Run files are plaintext, so they age out. The proof stays.

| Class | Plaintext (`prompt`, `output`) kept | After that |
| --- | --- | --- |
| public / internal | 90 days | text removed from the run file, `pruned: true` |
| confidential | 7 days | same |

- **Hashes stay, files are never deleted.** A fan-out replay needs every run.
- `replay` stays `OK` on a pruned file. The pruning step logs a `run.pruned`
  event with the new file hash, so the chain covers the change. The stored
  prompt/output hashes still match `run.started`/`run.finished`. Plaintext
  removed *before* the retention period is reported as a finding.
- **No CLI flag moves the deadline.** Retention periods are code, changed by review.
- The pruning step needs a trigger. It runs after every broker call, at most
  once an hour. A cleanup someone has to remember is not a cleanup.
- Your backups still hold the plaintext until *their* retention expires. Write
  that down next to the policy.

**Account caps.** Second engines run on subscriptions with limits. Track the
state per account (`ok → warn → exceeded`, plus `unknown`) and **notify only
when the state changes**, not on every run. Otherwise the alert channel becomes
noise. "Unknown" (login expired, usage endpoint silent) is not "free". It
blocks unless the caller explicitly overrides, and the override is logged.

## Failure modes & guards

| Failure mode | Guard |
| --- | --- |
| Confidential prompt sent to an engine without a contract | taxonomy gate before spawn; missing/broken taxonomy blocks |
| Gate script errors and is read as "allowed" | only an exact positive answer counts (lesson 3) |
| Engine reads files outside its lane | per-engine sandbox + bait test **with** positive control |
| Parent secrets leak into the engine | env built from an allowlist, never copied |
| Fake engine binary planted earlier in `PATH` | fixed search path, realpath, owner + mode check → exit 6 |
| Timeout kills only the leader; a grandchild holds the pipe and the run hangs | kill the **process group**; selftest checks wall time, not just "child gone" |
| Detached background child survives a normal exit | kill the group after every run, not only on timeout |
| Last runs cut off the end of the log | hash chain cannot see it: anchor the latest hash off-machine |
| Run vanishes from the record | `run.started` logged before any gate; every block ends with `run.finished` |
| Log tampered or truncated | hash chain + `replay` (exit 5 with file and line) |
| Chain breaks at month rollover or under threads | path per event under lock; thread lock over `flock` |
| Plaintext kept forever / pruned early | retention in code; replay flags early pruning |
| Two engines agree and both are wrong | roles: find / check / prove; verifier on all Class-A claims |
| Broker starts "deciding" | no synthesis in the broker. The conductor writes the answer |

## Minimal setup steps

1. **Pick one second engine** and decide its taxonomy entry: contract →
   `"in-house"`, no contract → `"external"`. Write the file, mode 0600.
2. **Run [scripts/broker-pocket.py](../scripts/broker-pocket.py) `selftest`**
   on every machine with an interpreter owned by you or root. All checks must
   pass. If the interpreter is rejected, the allowlist is doing its job.
3. **Adapt the engine table** to `--help` of the CLI version you installed.
   Prompt over stdin or a lane file, never argv.
4. **Add a real sandbox per engine** and prove it with a bait file in your
   home, plus a positive control (the engine must read its own lane file).
5. **Route every second-engine call through the broker.** A direct call
   bypasses the log, and any control that counts runs from the log is blind to it.
6. **Add retention and a state-change-only cap alert** before you put the
   broker into a scheduled job.
7. **For decisions that matter, use fan-out with roles** and let the
   conductor synthesize. Then run the verifier from chapter 08.

The pocket reference (`scripts/broker-pocket.py`, Python ≥ 3.9, stdlib only)
implements guarantees 1–3, the class gate and `replay`, and its selftest
uses only local test doubles. It is about 400 lines you can read in one sitting. It has no sandbox profiles, quota caps,
fan-out or retention. Those are the parts you build for your own machines.
