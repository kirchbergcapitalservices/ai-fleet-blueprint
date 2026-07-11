# 01 — Architecture: The 5-Layer Model

> The one page that explains how everything fits. Every other doc zooms into one layer.

## Design goals

1. **No information loss** — anything an agent learns must survive machine loss, reboots, and rebuilds.
2. **Always-latest reads** — no agent answers from stale state.
3. **No silent failure** — if any of the above stops working, a human gets an alarm.
4. **Hub-optional** — the fleet keeps working (and keeps alarming) when the orchestrator laptop is offline.

## The layers

### Layer 0 — Hub & substrate: GitHub + git

Private GitHub repos are the **only** meeting point. No node hosts repos for another; nodes never sync git peer-to-peer. Every node has working checkouts only, and reads/writes exclusively against `origin`.

Why: off-site durability for free, every node independently rebuildable, and the hub laptop can disappear without breaking anyone else's reads or writes.

### Layer 1 — Shared truth (written knowledge)

Three repos, three different questions:

| Repo | Question it answers | Granularity |
|---|---|---|
| **wiki** | "What is *true*?" — domain knowledge: projects, people, decisions, infrastructure | atomic articles, 100–300 lines |
| **memory** | "What *happened*?" — episodic session memories, feedback rules, cost snapshots | one fact per file |
| **node-memory** | "What does each *node* know?" — per-node brains, worker session memories, shared conventions | per-node subtree |

All nodes have **read-write** access to all three (scoped deploy keys per repo per node). Each node writes its own slice and pushes immediately; everyone pulls before reading. See [02-llm-wiki.md](02-llm-wiki.md) and [03-memory-layers.md](03-memory-layers.md).

**Rule: no two systems claim the same truth.** The wiki holds timeless facts; memory holds episodes; node-memory holds per-node operational state. When you're unsure where something goes, that's a smell — answer "which question does this fact answer?"

### Layer 2 — Derived indexes (regenerated, never written)

Semantic search over documents, code graphs, cross-thread change detection, "who is working on what" rosters. These are **caches computed from layer 1**, so:

- They live **node-locally** and are *not* synced — each node regenerates its own on a schedule or post-commit hook.
- Nobody ever hand-edits one. If an index is wrong, fix the truth (layer 1) or regenerate.
- Never treat an index as a source of truth: an empty search result means "look at the wiki," not "invent an answer."

### Layer 3 — Exchange discipline (behavior, not a service)

"No loss + always latest" is enforced as **per-node behavior**:

| Behavior | Mechanism |
|---|---|
| Pull at start | Every session/job begins with `git pull` on the repos it touches |
| Write → push immediately | Nothing sits uncommitted; unpushed work is treated as a defect |
| Safe writes only | `git pull --rebase --autostash` + bounded push-retry; **abort on conflict** rather than clobber ([04-multi-writer-git.md](04-multi-writer-git.md)) |
| Hourly backstop | A hygiene watcher per node: fast-forward pulls when clean+behind, alerts on dirty/unpushed — never auto-pushes |
| Memory self-push | Each worker pushes its own session memories to node-memory on a cron (worker-owned) |
| Hub pull-backstop | The hub also pulls all nodes' memories daily — a second, independent copy path |

Self-push and pull-backstop target the same subtree with identical content, so they **converge** — whoever runs second finds no diff. That redundancy is deliberate: the self-push works when the hub travels; the hub pull works if a worker's cron dies.

### Layer 4 — Watchdogs (dead-man's-switches)

Layer 3 must never fail *silently*. Every scheduled job writes a **heartbeat file**; watchers check freshness and content:

- **Per-node health aggregator** (daily): are the launch agents loaded? Are logs/heartbeats fresh? Are the other nodes' checkouts within N commits of origin? Endpoint probes for services (a process can be alive but wedged — probe the endpoint, not the PID).
- **Hub-independent alerter**: one worker also checks the *other* nodes' heartbeats and alerts directly (push notification), so alarms fire even when the hub laptop is off. This is the piece most setups miss.
- **Alert-only vs self-healing**: watchdogs that *restart* things fight with the service manager; prefer KeepAlive/daemon supervision for healing and keep watchdogs alert-only.

See [06-watchdogs.md](06-watchdogs.md).

## Why peer-symmetric (the shift that mattered)

The first version of this fleet was hub-centric: the laptop pulled every node's data, distributed updates, and ran the only health check. It worked — until the laptop was off for a day. Then backups paused, **and the watcher that would have complained was off too.**

The fix is symmetry: every node pulls itself fresh, backs itself up, and watches itself; the hub's own pulls and checks remain as a second pair of eyes, not as a dependency. GitHub is the only shared point, and GitHub is the component you already trust to be up.

## Failure modes & guards (summary)

| Failure | Guard |
|---|---|
| Node rebuilt, local knowledge gone | Layer 1 all-nodes-RW + memory self-push (nothing exists on only one machine) |
| Agent answers from stale state | pull-at-start + hourly hygiene ff-pull |
| Two nodes edit the same file | safe-push aborts on rebase conflict → escalate to human; never clobber |
| Backup cron dies quietly | heartbeat file + daily aggregator + hub-independent alerter |
| Hub offline for days | workers self-push + worker-side alerter keep running |
| Reboot wipes `/tmp` heartbeats | expect false-stale after reboot; kickstart jobs or persist heartbeats |

## Minimal setup steps

1. Create the three private repos (wiki, memory, node-memory).
2. Give every node a checkout + scoped deploy keys (RW where it writes).
3. Install the discipline scripts ([scripts/](../scripts/)) + crontabs per node.
4. Add heartbeats + the health aggregator; put a second alerter on a worker.
5. Write the rules into each node's `CLAUDE.md` ([templates/](../templates/)) — behavior beats tooling.
