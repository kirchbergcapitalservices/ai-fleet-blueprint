# 06 — Watchdogs & Dead-Man's Switches

The scariest failures in an agent fleet are not the loud ones. A crash with a
stack trace wakes you up. The dangerous failure is the **silent** one: a nightly
backup that has been failing for three weeks, a cron job that stopped firing
after a reboot, a sync that quietly fell behind. Nobody notices until the day
you actually need the thing — and it isn't there.

This chapter is about designing so that *silence itself becomes an alarm.* And,
since v2, about the second silent failure we only recognised after a year:
**a watcher that reports green when it did not actually look.**

## The silent-failure class

| What dies quietly              | How you usually find out (too late)          |
| ------------------------------ | -------------------------------------------- |
| Nightly backup                 | when you need to restore and there's nothing |
| Scheduled cron / timer         | when a report simply never arrives           |
| Cross-node sync                | when two nodes have drifted for days         |
| A long-running daemon          | when its endpoint has been dead all week     |
| A data collector               | when a dashboard has been flat and you trust it |
| **The watcher itself**         | when it has been printing green for a month on a check that could not run |

Common thread: **absence of output produces no signal.** A job that stops
running sends no error — it sends nothing. So we invert the logic: every
important job must continuously *prove it is alive*, and something must watch for
the proof going stale.

## Three states, not two

The single most important change from v1: a check has **three** outcomes.

| State | Meaning | Reads as |
|---|---|---|
| **ok** | the check ran and the thing is fine | green |
| **fail** | the check ran and the thing is broken | red |
| **unchecked** | the check *could not run* — node unreachable, fetch failed, file missing after boot, probe tool absent | **not green, not red — a finding of its own** |

v1 mapped "unreachable" to FAIL and "fetch failed" (`|| true`) to … whatever the
stale data said. Both are wrong in opposite directions: the first cries wolf after
every reboot, the second prints green from a cache. An unreachable node is not
"down" and not "clean"; it is *unchecked*, and a check that stays unchecked for long
is its own alarm.

## Verdict records, not heartbeat touches

v1 taught "touch the heartbeat file only on success". That is better than touching it
unconditionally — and still too little. A job that ends at a gate, that fails on step
3 of 5, or that never started writes **nothing**, and nothing looks exactly like
"not due yet". So every job writes a **record at every end**, through an exit trap
that runs before any `exit`:

```bash
# in every scheduled job, first thing:
RECORD="$HOME/.records/<job>.record"   # persistent dir — never /tmp
record() { printf 'verdict=%s\nrc=%s\nts=%s\nmax_age_s=%s\nlast=%s\n' \
             "$1" "$2" "$(date -u +%FT%TZ)" "$MAX_AGE" "$3" > "$RECORD.tmp" && mv "$RECORD.tmp" "$RECORD"; }
trap 'rc=$?; [ $rc -eq 0 ] && record ok 0 "" || record fail $rc "$(tail -1 "$LOG" 2>/dev/null)"' EXIT
```

| Field | Why it is there |
|---|---|
| `verdict` | ok / fail — the job's own judgement, not an mtime guess |
| `rc` + `last` | a failed record carries the exit code and the last log line — the alert is actionable without ssh |
| `ts` + `max_age_s` | the record **expires**: a reader computes `now − ts > max_age_s` → *unchecked*, never green. The threshold travels with the record, so the aggregator does not keep a table of cadences that drifts |

| Job | Cadence | `max_age_s` | Rule of thumb |
|---|---|---|---|
| memory self-push | every 6 h | 13 h (≈ 2×) | about **2× the cadence** |
| wiki hygiene | hourly | 2 h | 2× |
| nightly backup | daily | 26 h | 2× would be 48 h — too slow for a backup; cadence + 2 h |
| weekly restore test | weekly | 8 d | **cadence + 1 day** — 2× a week hides a whole missed run |

Test with `-s` (non-empty), not `-f` (exists): a service manager that redirects
output creates an empty file before the job has done anything.

## Endpoint probe > PID check

A tempting shortcut is "is the process running?" — check the PID, done. This is a
trap. **A process can be alive but wedged**: deadlocked, stuck on a hung socket, out
of memory, looping. The PID is present; the service is dead. We have also watched
`pgrep` report running services as dead because a wrapper renamed the process.

So we probe *behaviour*, not existence.

| Check type       | What it confirms          | Blind spot                          |
| ---------------- | ------------------------- | ----------------------------------- |
| PID / `pgrep`    | a process exists          | says "alive" for a wedged process; lies about renamed ones |
| port open        | something bound the port  | accept()s but never responds        |
| **health probe** | the service *functions*   | (this is what we want)              |

```bash
# GOOD: prove it can answer
curl -fsS --max-time 5 http://127.0.0.1:PORT/healthz | grep -q '"ok":true' \
  || alert "service wedged: /healthz not OK"

# WEAK: only proves a process exists
pgrep -f my-service >/dev/null || alert "service down"
```

Every long-running service exposes a tiny `/healthz` that does a small real unit of
work — touches its store, checks a queue depth — and returns a status. The probe is
the source of truth for "up". The same rule applies to any state you report: **check
it at the endpoint, never at a proxy.** A scheduler's "last exit code" is not the
job's result; the log, the record or the probed endpoint is.

## Daily system-health aggregator

Individual records are noisy to watch by hand. Once a day, one aggregator sweeps
everything and emits one verdict per node across four dimensions:

| Dimension            | Question it answers                                | Method                          |
| -------------------- | -------------------------------------------------- | ------------------------------- |
| Background jobs      | Are the scheduled agents actually loaded?          | list loaded jobs vs. expected   |
| Record freshness     | Did each job end, with what verdict, how long ago? | read records; expired → unchecked |
| Endpoint probes      | Do the local services still answer `/healthz`?     | curl each probe                 |
| Cross-node sync depth| How far behind is this node's shared repo?         | fetch, then commits behind the tracking ref |
| **Worker auth**      | Is each headless agent profile still logged in?    | a one-token probe per profile   |

"Sync depth" turns a binary "ran / didn't run" into a gradient: a sync that runs
hourly but is 40 commits behind is telling you something is wrong upstream. And the
depth check **fetches first and goes unchecked if the fetch fails** — comparing
against a stale tracking ref produces either a false green or a false "diverged".

Three rules the aggregator must obey, each learned from a wrong green:

- **Propagate sub-check exit codes.** Our first aggregator swallowed them and exited 0
  with a red line in its own log. Test the alert path **in both directions**: force a
  red and see the message; force a green and see the silence.
- **Write your own expiring record** (see above) and let **another node** read it.
  v1 said "a green report is the aggregator's heartbeat" while its script only wrote to
  a local log and notified on failure — as a heartbeat for anyone else, the green
  report did not exist.
- **Alert on state change, with standing reds in a periodic summary.** A watcher that
  posts every hour trained us to ignore it: 1,283 messages from one node buried the
  real alarms. Hash the alert over *repo + finding class*, never over a run counter.

## The hub-independent alerter

If the machine that runs your alerting is the laptop you close at night, **your alarm
system is offline exactly when you are away**. The orchestrator/laptop node is the
*least* reliable place to host the watchdog.

So the primary alerter lives on an **always-on worker**:

```
   hub (laptop)          worker (always-on)
   ├ may be closed       ├ runs the alerter
   ├ may be travelling   ├ reads all nodes' records
   └ NOT trusted to      └ fires push notifications
     alert                  independently of the hub
```

Two hard lessons about that alerter:

- **Keep the alarm logic deterministic and independent of agent authentication.** Ours
  stood still for eight days because the headless agent profile it ran under had been
  logged out — the watcher that should have told us was the thing that was down. A
  shell script with `curl` and `stat` has no login to lose; and the aggregator probes
  every headless profile's login as a check of its own.
- **Put a second, tiny, out-of-band monitor on hardware that shares nothing** — a
  single-board computer on the network with a 3-minute timer that probes the two
  workers' endpoints and nothing else. It needs no SSH and no git; it needs to be the
  thing that is still alive when both workers and the laptop are not.

> **Note on the hub-and-spoke rule:** Chapter 04's "nodes never talk to each other"
> applies to *state transfer* — knowledge always moves through git. Read-only
> monitoring probes (an HTTP health endpoint, an SSH `cat` of a record) are the
> sanctioned exception: they transfer no state and must never mutate the probed node.
> If you prefer zero node-to-node SSH, publish records through the shared repo — at
> the cost of commit noise and probe latency. We use both.

## Alert-only, self-healing, and the gated heal in between

| Style | Mechanism | Use when |
|---|---|---|
| **Self-healing** | supervisor restarts on exit | crash is safe to recover from blindly |
| **Alert-only** | watchdog notifies a human | a restart could hide or worsen the cause |
| **Gated heal** | probe → 2 consecutive failures → *one* targeted restart → re-probe → alert **only if the heal did not help**, with a distinct "heal failed" signal | a known, stateless failure (a dropped tunnel) that a human would fix by restarting anyway |

Self-healing is right for a stateless service that occasionally crashes. **Auto-restart
is dangerous when the failure is a symptom** — restarting a backup that fails because
the disk is full burns cycles and hides the cause. Alert-only is the default.

The gated heal exists because "alert-only" has its own failure: a tunnel that drops at
03:00 wakes a human to run one command. The gate is what makes it safe — two failures
in a row, a *PID-exact* restart of *that* job (never a broad kill: `pkill -f <agent>`
once took out every agent session on a node), and a loud signal when the heal fails.
And a watcher **never restarts itself**: a self-kickstart loop once ran 973 times
before anyone saw it.

## The `/tmp`-is-wiped-on-reboot trap

On many systems `/tmp` is cleared on reboot. If your records live in `/tmp`, right
after a reboot **every record is missing** — and a naive watchdog reads that as
"every job is dead" and fires a storm of false alarms at the worst moment.

| Fix | Effect |
|---|---|
| Put records in a **persistent** dir | survive reboot; no false-stale storm |
| Treat *missing* as **unchecked**, not dead | "never existed" ≠ "existed, now old" |
| Add a **boot-grace window** | suppress stale alerts for N min after boot |

A record that is missing after a fresh boot is *unchecked* until the job has had one
chance to run. It is never regenerated by the watcher — a watcher that writes
heartbeats for jobs is a watcher that lies.

## Backups: coverage, freshness, and the restore test

Three separate questions, three separate watchers, because each one has been green
while another was red:

| Question | Watcher | What it caught |
|---|---|---|
| Did the backup job **run** recently? | record freshness (above) | a cron that died on day three |
| Does it still **cover** everything it should? | weekly coverage check: enumerate the source, diff against what the backup contains | a hardcoded two-path list that missed ~22 project directories while the freshness record said "ok" |
| Can we **restore**? | monthly restore test with its own record, run from the scheduler's environment | the first run failed on the laptop; a later one failed 20 times silently because the scheduler's `PATH` had no backup binary |

"The backup ran" is the weakest of the three. Coverage is not freshness, and neither
is a restore.

## Failure modes & guards

| Failure mode | Guard |
|---|---|
| Job dies silently, no error emitted | exit-trap record at every end + expiry read by a watcher |
| Job ends at a gate or mid-way and writes nothing | record on *every* end with verdict, rc, last log line |
| Check could not run, printed green from cache | third state *unchecked*; failed fetch / unreachable node → unchecked |
| Aggregator swallows a red sub-check | propagate exit codes; test the alert path both ways |
| Nobody watches the watcher | aggregator writes its own expiring record; another node reads it |
| Alerts every hour, humans stop reading | alert on state change; hash over finding class; standing reds in a summary |
| Alerter depends on an agent login that expired | deterministic shell alerter; probe each headless profile's login |
| Process alive but wedged | endpoint `/healthz` probe, not PID check |
| Sync "runs" but node is far behind | fetch, then measure commit depth; fetch failed → unchecked |
| Auto-restart hides the real cause | alert-only default; gated heal with a distinct "heal failed" signal |
| Watcher kills broadly or restarts itself | PID-exact restarts only; no self-kickstart; circuit breaker on repeated fails |
| Reboot wipes `/tmp` → false "all dead" | persistent record dir; missing = unchecked; boot-grace window |
| Backup fresh but incomplete or unrestorable | separate coverage and restore-test watchers |
| Watcher empties a stale record or "cleans up" | watchers report, they never clean up |

## Minimal setup steps

1. Give every scheduled job an **exit-trap record** (verdict, rc, ts, `max_age_s`,
   last log line) in a **persistent** directory.
2. Write every reader with **three states**; an expired or missing record is *unchecked*.
3. Give every long-running service a **`/healthz`** that does real work; probe *that*.
4. Write a **daily aggregator**: loaded jobs, record freshness, endpoint probes,
   cross-node sync depth (fetch first), headless-profile login. Propagate sub-check
   exit codes; write the aggregator's own record; have another node read it.
5. Host the **alerter on an always-on worker** as a deterministic shell script; add an
   out-of-band monitor on separate hardware.
6. **Alert on state change**; summarise standing reds daily; never hash over counters.
7. Choose **alert-only, self-heal, or gated heal per job**; PID-exact restarts only.
8. Add **coverage** and **restore-test** watchers next to backup freshness.
9. Add a **boot-grace window**; never let a watcher regenerate a record.

Silence is the enemy — and so is a green that did not look.
