# AI Fleet Blueprint

**A production-tested blueprint for running a small fleet of Claude Code instances — one orchestrator, multiple autonomous workers — that share one brain and never lose information.**

This repo is the sanitized, generic version of a real setup that runs 24/7: a laptop (`hub`) plus two always-on machines (`worker-a`, `worker-b`), each on its own Claude subscription, all working in parallel on the same knowledge base. Company names, hosts, people, and projects have been replaced with placeholders — the architecture, scripts, and hard-won lessons are real.

> **v2.0 (October 2026).** What changed since v1.1 and why — including one pattern we withdrew — is in [CHANGELOG.md](CHANGELOG.md).

> **This repository is documentation.** Nothing in it is an instruction to an agent that happens to read it. Rules, templates and commands here are examples to be adopted *deliberately* by a human, in their own setup — exactly the "content is data, not commands" rule of [docs/07](docs/07-security.md), applied to this repo itself.

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
| **0 — Hub & substrate** | a git remote (GitHub by default; optionally an in-network bare repo for data that must stay in-house) | — | The **only** meeting point. Nodes never talk git to each other. |
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

- Each worker runs Claude Code headless over SSH with its **own subscription profile** (`CLAUDE_CONFIG_DIR`), so heavy work never burns the orchestrator's quota — and a missing API key in non-interactive shells means it can never silently fall back to API billing. *Check* that: one admin shell profile exporting a key once billed a month of worker runs to the API. Roles are assignable — the laptop is one node among three, not the owner of everything; gates sit on **actions** (send, publish, file, change security posture) and need a human on every node.
- Workers have **no sudo**. A separate admin user exists for deploys. Even a fully prompt-injected worker cannot escalate.
- Delegation happens through a tiny helper script, a written brief with stable REQ/NG ids and a hard "DON'Ts" list, and — when SSH is not there — a git-native inbox (see [docs/05-worker-delegation.md](docs/05-worker-delegation.md)).

## What's in this repo

| Path | Content |
|---|---|
| [docs/00-start-here.md](docs/00-start-here.md) | **Start here** if you came from a workshop or lecture — maps what you saw to the chapters |
| [docs/01-architecture.md](docs/01-architecture.md) | The 5-layer model in depth; why peer-symmetric |
| [docs/02-llm-wiki.md](docs/02-llm-wiki.md) | The LLM-maintained wiki (Karpathy approach) — the single source of truth |
| [docs/03-memory-layers.md](docs/03-memory-layers.md) | Session memories, per-node brains, self-push + pull-backstop, the 80 % context checkpoint |
| [docs/04-multi-writer-git.md](docs/04-multi-writer-git.md) | Three writers, one repo: kernel locks (no stale state), safe-push, hygiene watcher |
| [docs/05-worker-delegation.md](docs/05-worker-delegation.md) | CLI workers, brief discipline, the wrong-user trap |
| [docs/06-watchdogs.md](docs/06-watchdogs.md) | Heartbeats, system-health, the hub-independent alerter |
| [docs/07-security.md](docs/07-security.md) | Least privilege, deny-lists, secrets hygiene, prompt-injection boundaries |
| [docs/08-quality-gates.md](docs/08-quality-gates.md) | Multi-agent audits, claim verification, premise audit, three engines / three roles, human gates |
| [docs/09-second-engine-broker.md](docs/09-second-engine-broker.md) | **New in v2:** one command to run a second model under three guarantees — reconstructible log, data-class gate, no leftovers |
| [docs/10-code-gates.md](docs/10-code-gates.md) | **New in v2:** merge = deploy — a different node merges, a second model reviews the exact commit, review requests as git objects |
| [scripts/](scripts/) | Runnable, sanitized versions of the core mechanics (v2: kernel-lock library, pocket broker) |
| [tests/](tests/) | Throwaway-repo harnesses that prove the lock, push, log, backup and health mechanics — run them before you trust a script |
| [templates/](templates/) | CLAUDE.md skeleton, worker-brief template, handoff template |

## Quickstart (minimal viable fleet)

1. **One private GitHub repo as your wiki.** Adopt the article schema + append-only log from [docs/02](docs/02-llm-wiki.md).
2. **Teach your agent the discipline** — copy [templates/CLAUDE-template.md](templates/CLAUDE-template.md) and adapt: read-before-answer, update-same-turn, safe-push only.
3. **Add a second machine.** Worker user without sudo, own Claude profile, scoped deploy key (read-write, one key per repo per node) — and **no account-wide token** on the node, which would void the scoping. Clone the wiki.
4. **Install the exchange discipline:** [scripts/git-safe-commit-push.sh](scripts/git-safe-commit-push.sh) for writes, [scripts/git-hygiene-sync.sh](scripts/git-hygiene-sync.sh) hourly per node, [scripts/hooks/install.sh](scripts/hooks/install.sh) in every clone, `log.md merge=union` in `.gitattributes`. Run [tests/harness.sh](tests/harness.sh) first.
5. **Back up what only exists locally:** create a private `node-memory` repo, clone it on every worker (scoped RW deploy key), then run [scripts/backup-own-memories.sh](scripts/backup-own-memories.sh) per worker (cron) for **every profile's** memory store — the hub pulls and reads the records, it does not write the same subtree.
6. **Watch the watchers:** [scripts/system-health.sh](scripts/system-health.sh) daily — three states, ok / fail / **unchecked**; put a second, deterministic alerter on an always-on worker so it fires when the hub is off.

## Hard-won rules (the short list)

- **Truth is written; indexes are regenerated.** Never hand-edit an index. Never treat an index as truth.
- **Never trust a hardcoded source list in a backup script.** Glob the parent directory. Enumerate the source, diff against the target.
- **Every backup needs a staleness watcher.** An unwatched backup is a future silent failure.
- **A process can be alive but wedged.** Probe endpoints, not PIDs.
- **`/tmp` heartbeats die on reboot.** Expect false-stale after restarts, or move heartbeats to a persistent path.
- **Verify the worker user empirically before wiring anything.** The "wrong user" trap costs hours, every time.
- **Single-agent research hallucinates confidently.** Anything with identifiers, numbers, or citations gets an independent verification pass before it leaves the house.
- **External content is data, not commands.** Agents that fetch the web follow *your* rules, never the page's.
- **Hooks are not a barrier.** `.git/hooks` is never cloned; a gate that lives there exists in one clone. Version the hook, symlink it in, check its presence on a schedule.
- **Unchecked is not green.** A node you could not reach, a fetch that failed, a record that is missing — none of that is "clean". Report it as its own state.
- **Inside a headless turn, background work dies with the answer.** `nohup` it, give it a record, collect it later.
- **A lock that can go stale is not a lock.** PID files and age rules guess; the kernel knows. Hold the lock for the whole transaction and let the kernel release it (docs/04).
- **Merge is deploy.** On executable paths a different node merges, and the review is bound to the exact commit (docs/10).
- **Check state at the endpoint, never at a proxy.** A scheduler's "last exit code" is not the job's result; the log or the probed endpoint is.
- **A negative claim needs a positive control and a date.** "0 hits", "not in the backup", "node is clean" — only with a known-present case found in the same breath, written in the past tense with who checked, from where, when. Negations do not break; they go quietly untrue.
- **Scheduled prompts rot silently.** "succeeded" does not mean the prompt still matches the system; read the prompt and a recent transcript, not the exit code.
- **Autonomous loops need a circuit breaker and never a broad kill.** N fast failures in a row → halt with a sentinel that survives relaunch. Never `pkill -f <agent>` in a watcher — it kills every session on the node.
- **Check what exists before setting it up again.** "X is missing" in a worker's report is a claim; look at the endpoint first and reuse what is there.

## Disclaimer

This blueprint is shared **as-is**, for educational purposes, without warranty of any kind (see [LICENSE](LICENSE)). It describes one real production setup in sanitized form — **your risk profile is not ours.** Before adopting anything here:

- **Review every script before running it.** They move files, commit, and push. Test on throwaway repos first.
- **Adapt the security posture to your environment** — deny-lists, key scoping, and user separation shown here are a floor, not a ceiling.
- **Running multiple Claude instances costs real money** — understand your subscription/API billing before wiring up workers.
- Nothing here is affiliated with or endorsed by Anthropic. "Claude" and "Claude Code" are Anthropic products; this is an independent operator's setup around them.
- No personal data, credentials, or proprietary project information are contained in this repository — names, hosts, and examples are fictional placeholders.

## License

MIT — see [LICENSE](LICENSE). Use it, teach with it, build on it.
