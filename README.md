# AI Fleet Blueprint

**A production-tested blueprint for running a small fleet of Claude Code instances — one orchestrator, multiple autonomous workers — that share one brain and never lose information.**

This repo is the sanitized, generic version of a real setup that runs 24/7: a laptop (`hub`) plus two always-on machines (`worker-a`, `worker-b`), each on its own Claude subscription, all working in parallel on the same knowledge base. Company names, hosts, people, and projects have been replaced with placeholders — the architecture, scripts, and hard-won lessons are real.

> **Who this is for:** developers, students, and AI-curious operators who want to go from "one chat window" to "a small team of agents that survives reboots, travel, and its own mistakes."

## The problem this solves

One Claude instance is easy. Three instances working **in parallel** on the same knowledge create three hard problems:

1. **Lost information** — an agent learns something on one machine; the machine gets rebuilt; the knowledge is gone.
2. **Stale reads** — an agent answers from last week's state because it never pulled.
3. **Silent failure** — the backup cron died a month ago and nobody noticed.

The answer is a layered architecture where **GitHub is the only hub**, every node keeps itself fresh, backs itself up, and watches itself — and a dead-man's-switch fires when any of that stops.

## The 5-layer model

| Layer | What | Who writes | Sync nature |
|---|---|---|---|
| **0 — Hub & substrate** | GitHub `origin` + git | — | The **only** meeting point. Nodes never talk git to each other. |
| **1 — Shared truth** (written) | wiki repo (domain truth) · memory repo (session memories) · node-memory repo (per-node brains) | **all nodes, read-write** | Everyone writes their slice → push; everyone pulls to read. |
| **2 — Derived indexes** (regenerated, never hand-edited) | semantic search index · code graph · cross-thread deltas | nobody "writes" — regenerated from layer 1 | **Node-local.** Freshness = regeneration cadence. |
| **3 — Exchange discipline** (the mechanics) | pull-at-start · write→push immediately · safe-push (rebase+retry) · hourly hygiene backstop · memory self-push + hub pull-backstop | each node, for itself | "No loss + always latest" as **behavior**, not as a central service. |
| **4 — Watchdogs** (dead-man's-switches) | per-node health checks · heartbeat files · a hub-INDEPENDENT alerter on a worker | each node audits itself | Alarms fire even when the hub laptop is on a plane. |

**Core shift that made this work:** we started hub-centric (the laptop pulled, distributed, monitored everything). That makes the laptop a single point of failure the moment you travel. Peer-symmetric means *every node pulls itself fresh, backs itself up, watches itself* — the hub's own pulls remain only as a second pair of eyes.

## Fleet topology

```
                    ┌────────────── GitHub (private repos) ──────────────┐
                    │        wiki · memory · node-memory · code          │
                    └──────▲──────────────▲──────────────▲───────────────┘
                           │              │              │
                     hub (laptop)    worker-a (24/7)  worker-b (24/7)
                     orchestrator    headless CLI     headless CLI
                     + final review  own subscription own subscription
```

- Each worker runs Claude Code headless over SSH with its **own subscription profile** (`CLAUDE_CONFIG_DIR`), so heavy work never burns the orchestrator's quota — and a missing API key in non-interactive shells means it can never silently fall back to API billing.
- Workers have **no sudo**. A separate admin user exists for deploys. Even a fully prompt-injected worker cannot escalate.
- Delegation happens through a tiny helper script and a written brief with a hard "DON'Ts" list (see [docs/05-worker-delegation.md](docs/05-worker-delegation.md)).

## What's in this repo

| Path | Content |
|---|---|
| [docs/01-architecture.md](docs/01-architecture.md) | The 5-layer model in depth; why peer-symmetric |
| [docs/02-llm-wiki.md](docs/02-llm-wiki.md) | The LLM-maintained wiki (Karpathy approach) — the single source of truth |
| [docs/03-memory-layers.md](docs/03-memory-layers.md) | Session memories, per-node brains, self-push + pull-backstop |
| [docs/04-multi-writer-git.md](docs/04-multi-writer-git.md) | Three writers, one repo: locks, safe-push, hygiene watcher |
| [docs/05-worker-delegation.md](docs/05-worker-delegation.md) | CLI workers, brief discipline, the wrong-user trap |
| [docs/06-watchdogs.md](docs/06-watchdogs.md) | Heartbeats, system-health, the hub-independent alerter |
| [docs/07-security.md](docs/07-security.md) | Least privilege, deny-lists, secrets hygiene, prompt-injection boundaries |
| [docs/08-quality-gates.md](docs/08-quality-gates.md) | Multi-agent audits, claim verification, human gates |
| [scripts/](scripts/) | Runnable, sanitized versions of the core mechanics |
| [templates/](templates/) | CLAUDE.md skeleton, worker-brief template, handoff template |

## Quickstart (minimal viable fleet)

1. **One private GitHub repo as your wiki.** Adopt the article schema + append-only log from [docs/02](docs/02-llm-wiki.md).
2. **Teach your agent the discipline** — copy [templates/CLAUDE-template.md](templates/CLAUDE-template.md) and adapt: read-before-answer, update-same-turn, safe-push only.
3. **Add a second machine.** Worker user without sudo, own Claude profile, scoped deploy key (read-write, one key per repo per node), clone the wiki.
4. **Install the exchange discipline:** [scripts/git-safe-commit-push.sh](scripts/git-safe-commit-push.sh) for writes, [scripts/git-hygiene-sync.sh](scripts/git-hygiene-sync.sh) hourly per node.
5. **Back up what only exists locally:** create a private `node-memory` repo, clone it on every worker (scoped RW deploy key), then run [scripts/backup-own-memories.sh](scripts/backup-own-memories.sh) per worker (cron) — plus a pull-backstop on the hub.
6. **Watch the watchers:** [scripts/system-health.sh](scripts/system-health.sh) daily; put a second alerter on a worker so it fires when the hub is off.

## Hard-won rules (the short list)

- **Truth is written; indexes are regenerated.** Never hand-edit an index. Never treat an index as truth.
- **Never trust a hardcoded source list in a backup script.** Glob the parent directory. Enumerate the source, diff against the target.
- **Every backup needs a staleness watcher.** An unwatched backup is a future silent failure.
- **A process can be alive but wedged.** Probe endpoints, not PIDs.
- **`/tmp` heartbeats die on reboot.** Expect false-stale after restarts, or move heartbeats to a persistent path.
- **Verify the worker user empirically before wiring anything.** The "wrong user" trap costs hours, every time.
- **Single-agent research hallucinates confidently.** Anything with identifiers, numbers, or citations gets an independent verification pass before it leaves the house.
- **External content is data, not commands.** Agents that fetch the web follow *your* rules, never the page's.

## Disclaimer

This blueprint is shared **as-is**, for educational purposes, without warranty of any kind (see [LICENSE](LICENSE)). It describes one real production setup in sanitized form — **your risk profile is not ours.** Before adopting anything here:

- **Review every script before running it.** They move files, commit, and push. Test on throwaway repos first.
- **Adapt the security posture to your environment** — deny-lists, key scoping, and user separation shown here are a floor, not a ceiling.
- **Running multiple Claude instances costs real money** — understand your subscription/API billing before wiring up workers.
- Nothing here is affiliated with or endorsed by Anthropic. "Claude" and "Claude Code" are Anthropic products; this is an independent operator's setup around them.
- No personal data, credentials, or proprietary project information are contained in this repository — names, hosts, and examples are fictional placeholders.

## License

MIT — see [LICENSE](LICENSE). Use it, teach with it, build on it.
