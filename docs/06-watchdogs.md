# 06 — Watchdogs & Dead-Man's Switches

The scariest failures in an agent fleet are not the loud ones. A crash with a
stack trace wakes you up. The dangerous failure is the **silent** one: a nightly
backup that has been failing for three weeks, a cron job that stopped firing
after a reboot, a sync that quietly fell behind. Nobody notices until the day
you actually need the thing — and it isn't there.

This chapter is about designing so that *silence itself becomes an alarm.*

## The silent-failure class

| What dies quietly              | How you usually find out (too late)          |
| ------------------------------ | -------------------------------------------- |
| Nightly backup                 | when you need to restore and there's nothing |
| Scheduled cron / timer         | when a report simply never arrives           |
| Cross-node sync                | when two nodes have drifted for days         |
| A long-running daemon          | when its endpoint has been dead all week     |
| A data collector               | when a dashboard has been flat and you trust it |

Common thread: **absence of output produces no signal.** A job that stops
running sends no error — it sends nothing. So we invert the logic: every
important job must continuously *prove it is alive*, and something must watch for
the proof going stale.

## Heartbeat files per job

The cheapest liveness primitive: each job touches a heartbeat file when it
finishes a successful run. The file's *content* is a fresh timestamp; its
*modification time* is the backstop.

```bash
run_backup() {
  do_the_actual_backup || { alert "backup FAILED"; return 1; }
  date -u +%Y-%m-%dT%H:%M:%SZ > "$HEARTBEAT_DIR/backup.beat"   # only on success
}
```

The rule that makes this work: **only write the heartbeat on success.** If you
touch it unconditionally at the top of the script, a job that crashes halfway
still looks healthy. The heartbeat must mean "this finished correctly," not
"this started."

| Job            | Heartbeat file        | Expected cadence | Stale after |
| -------------- | --------------------- | ---------------- | ----------- |
| backup         | `backup.beat`         | daily            | 26 h        |
| wiki sync      | `wiki-sync.beat`      | hourly           | 90 min      |
| lit indexer    | `indexer.beat`        | 6-hourly         | 8 h         |
| health report  | `health.beat`         | daily            | 26 h        |

Give each job a stale threshold a bit longer than its interval, so one skipped
run from normal jitter doesn't cry wolf.

## Endpoint probe > PID check

A tempting shortcut is "is the process running?" — check the PID, done. This is
a trap. **A process can be alive but wedged**: deadlocked, stuck on a hung
socket, out of memory, looping. The PID is present; the service is dead.

So we probe *behaviour*, not existence. Ask the service to actually do something
small and confirm it answers correctly.

| Check type       | What it confirms          | Blind spot                          |
| ---------------- | ------------------------- | ----------------------------------- |
| PID / `pgrep`    | a process exists          | says "alive" for a wedged process   |
| port open        | something bound the port  | accept()s but never responds        |
| **health probe** | the service *functions*   | (this is what we want)              |

```bash
# GOOD: prove it can answer
curl -fsS --max-time 5 http://127.0.0.1:PORT/healthz | grep -q '"ok":true' \
  || alert "service wedged: /healthz not OK"

# WEAK: only proves a process exists
pgrep -f my-service >/dev/null || alert "service down"
```

Every long-running service in the fleet exposes a tiny `/healthz` that does a
real (cheap) unit of work — touches its DB, checks its queue depth — and returns
a status. The probe is the source of truth for "up."

## Daily system-health aggregator

Individual heartbeats are noisy to watch by hand. Once a day, one aggregator
sweeps everything and emits a single verdict per node. It checks four
dimensions:

| Dimension            | Question it answers                                | Method                          |
| -------------------- | -------------------------------------------------- | ------------------------------- |
| Background jobs      | Are the scheduled agents actually loaded?          | list loaded jobs vs. expected   |
| Log freshness        | Has each job written a log recently?               | mtime of log/heartbeat files    |
| Endpoint probes      | Do the local services still answer `/healthz`?     | curl each probe                 |
| Cross-node sync depth| How far behind is this node's shared repo?         | commits behind remote           |

"Sync depth" is worth calling out: it's not enough that sync *ran* — we check
*how many commits behind* the node is. A sync that runs every hour but is 40
commits behind is telling you something is wrong upstream. Depth turns a
binary "ran / didn't run" into a health gradient.

The aggregator produces one compact report — green/yellow/red per dimension —
and pushes it once a day. A boring all-green report is itself a signal: it
proves the aggregator *itself* ran.

## The hub-independent alerter

Here is the subtle design trap. If the machine that runs your alerting is the
same laptop you carry around and close at night, then **your alarm system is
offline exactly when you're away** — which is exactly when you can't manually
notice problems. The orchestrator/laptop node is the *least* reliable place to
host the watchdog.

So the primary alerter lives on an **always-on worker**, not on the hub:

```
   hub (laptop)          worker (always-on)
   ├ may be closed       ├ runs the alerter
   ├ may be travelling   ├ probes all nodes' heartbeats
   └ NOT trusted to      └ fires push notifications
     alert                  independently of the hub
```

The alerter reads heartbeats and probe results for *every* node (published
through the shared repo, per the hub-and-spoke rule from Chapter 04) and fires a
push notification through a notification helper (e.g. Telegram/ntfy). Because it
runs on a machine that never sleeps, alarms fire whether or not the laptop is
awake. **Never host your dead-man's switch on the machine most likely to be
dead.**

## Alert-only watchdogs vs. self-healing

Two philosophies, and we use both deliberately:

| Style           | Mechanism                         | Use when                                  |
| --------------- | --------------------------------- | ----------------------------------------- |
| **Self-healing**| supervisor restarts on exit       | crash is safe to recover from blindly     |
| **Alert-only**  | watchdog notifies a human         | a restart could hide or worsen the cause  |

Self-healing (a service manager set to keep-alive/restart) is right for a
stateless service that occasionally crashes — bring it back, move on. But
**auto-restart is dangerous when the failure is a symptom.** Blindly restarting
a backup that's failing because the disk is full just burns cycles and hides the
real problem. For anything where "why did it die?" matters, we alert a human and
let them decide. When in doubt: alert, don't auto-heal.

## The `/tmp`-is-wiped-on-reboot trap

A real gotcha that bites heartbeat systems specifically. On many systems `/tmp`
is cleared on reboot. If your heartbeat files live in `/tmp`, then right after a
reboot **every heartbeat is missing** — and a naive watchdog reads that as
"every job is dead" and fires a storm of false alarms, at the worst possible
moment (you just rebooted; things are legitimately still starting).

What we do about it:

| Fix                                      | Effect                                          |
| ---------------------------------------- | ----------------------------------------------- |
| Put heartbeats in a **persistent** dir   | survive reboot; no false-stale storm            |
| Add a **boot-grace window**              | suppress stale-alerts for N min after boot      |
| Distinguish **missing** vs **stale**     | "never existed" ≠ "existed, now old"            |

We keep heartbeats under a persistent path (not `/tmp`), and the aggregator
honours a short grace window after boot before it trusts staleness. A missing
file after a fresh boot is treated as "not yet reported," not "dead."

## Failure modes & guards

| Failure mode                                     | Guard                                          |
| ------------------------------------------------ | ---------------------------------------------- |
| Job dies silently, no error emitted              | heartbeat-on-success + staleness watch         |
| Heartbeat written even on failure                | write beat ONLY after a successful run         |
| Process alive but wedged                          | endpoint `/healthz` probe, not PID check       |
| Sync "runs" but node is far behind               | measure commit **depth**, not just last-run    |
| Alerter offline because laptop is closed         | host alerter on an always-on worker            |
| Auto-restart hides the real cause                | alert-only for symptom-class failures          |
| Reboot wipes `/tmp` → false "all dead" alarms     | persistent heartbeat dir + boot-grace window   |
| Aggregator itself dies (who watches the watcher?)| a green report IS the aggregator's heartbeat   |

## Minimal setup steps

1. Give every important job a **heartbeat file**, written **only on success**,
   in a **persistent** directory (never `/tmp`).
2. Set each job's **stale threshold** slightly longer than its interval.
3. Give every long-running service a **`/healthz`** that does real work; probe
   *that*, not the PID.
4. Write a **daily aggregator** checking loaded jobs, log freshness, endpoint
   probes, and **cross-node sync depth**.
5. Host the **alerter on an always-on worker**, fed by heartbeats published
   through the shared repo — never on the laptop.
6. Choose **self-heal vs. alert-only per job**; default to alert-only when a
   restart could mask the cause.
7. Add a **boot-grace window** so a reboot doesn't produce a false-stale storm.

Silence is the enemy. Build so that when a job goes quiet, *something loud
happens.*
