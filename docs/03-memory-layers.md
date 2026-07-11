# 03 — Memory architecture: three stores, not one

> "Memory" is an overloaded word. In a fleet it means at least three different things with
> three different lifetimes and three different owners. Conflating them is the first
> mistake, and it's a quiet one — everything works until two stores disagree.

## Why session memories are not wiki truth

The previous chapter built the wiki: the canonical, mutable, cross-linked record of
*domain truth*. It is tempting to also throw session-level scraps into it — "the user
prefers terse answers," "worker-b was down last night," "I tried approach X and it
failed." Don't. Those are **episodic memories**: true about a moment, a session, or a
node, not about the domain.

The distinction that matters:

| | Domain truth (wiki) | Episodic memory |
|---|---|---|
| Answers | "What is true about the world we work in?" | "What happened / what do I prefer / what did I try?" |
| Lifetime | Until the world changes | Until it's superseded or irrelevant |
| Scope | Shared, global | Session-local or node-local |
| Example | "The ingest API caps at N req/s" | "Last run I hit the cap and backed off" |
| Fold into wiki? | Yes — it's the wiki | No — it would pollute domain truth |

Put episodic content in the wiki and you get an article that's half fact, half diary,
trustworthy as neither. Keep them separate and each stays clean: the wiki you can ground
an answer on; the episodic store you can use to remember *how you work* without corrupting
*what is true*.

## The three stores

A fleet of one orchestrator (`hub`) and two workers (`worker-a`, `worker-b`) runs three
memory stores, each a git repo:

| Store | Contents | Mutability | Owner / scope | Analogy |
|---|---|---|---|---|
| **The wiki repo** | Domain truth — atomic, cross-linked articles | Mutable in place | Shared; curated by hub | The library |
| **The memory repo** | Episodic session memories — what happened, preferences, per-session learnings | Append-mostly | Shared across nodes | The diary |
| **The node-memory repo** | Per-node "brains" + shared conventions every node obeys | Mutable per-node subtree; shared conventions curated | One subtree per node, plus a common subtree | Each worker's personal notebook + the house rules |

Three stores, three jobs:

- **Wiki repo** — "what is true." Read before answering (chapter 02).
- **Memory repo** — "what happened, and how the user likes things." Read at session start
  to recover context that isn't domain truth.
- **Node-memory repo** — "who am I, and what rules do all of us follow." Each node has its
  own subtree (its identity, its local quirks, its in-flight work) plus a shared subtree
  of conventions no node may violate.

The node-memory split is worth dwelling on. `worker-a/` and `worker-b/` are private
brains — a node writes freely to its own subtree and never to another's. `shared/` holds
the conventions (naming, commit rules, boundaries) that bind the whole fleet. This gives
you node autonomy without divergence: nodes think independently but obey the same house
rules.

## Getting memory home: self-push + pull-backstop

A memory a node never persists is a memory that dies when the session does. Two mechanisms,
belt and suspenders, get memory off a node and into the shared repos.

**Worker self-push (primary).** Each worker is responsible for its own persistence:

- A scheduled job (e.g. every 30 min, example cadence) commits and pushes that node's
  memory subtree.
- A **heartbeat file** is touched on every successful push — a tiny file whose timestamp
  says "this node last persisted at T."

**Hub pull-backstop (secondary).** The hub periodically pulls all subtrees. If a worker's
self-push is broken, the hub still gathers whatever the worker managed to commit locally,
and — crucially — the hub watches the heartbeats. A heartbeat that stops advancing is the
alarm that a worker has gone silent.

| Mechanism | Runs on | Frequency | Job |
|---|---|---|---|
| Self-push | each worker | e.g. every 30 min | Commit + push own subtree; touch heartbeat |
| Heartbeat file | each worker | every push | Record "last persisted at T" |
| Pull-backstop | hub | e.g. every hour | Gather subtrees; **check heartbeats for staleness** |

## Convergence: same subtree, no double-commit

With multiple writers and a pulling hub, the failure you must design out is the
**double-commit** — two actors committing the same change, or two actors writing the same
path and clobbering each other.

The rule that makes it converge:

> **Every path has exactly one writer.**

- Each node writes **only** its own subtree (`worker-a/` written only by `worker-a`).
- The hub **pulls and reads** everything but **writes** only the curated/shared areas it
  owns.
- Shared conventions are edited via the hub's curation flow (branch → review → merge),
  not written directly by workers.

Because writers are partitioned by path, concurrent pushes touch disjoint files and merge
without conflict. The hub's pull is read-only over the workers' subtrees, so it never
races a worker's write. No path has two writers; nothing double-commits.

## The dead-man's-switch principle (a hard lesson)

> **A backup without a staleness watcher is not a backup. It's a future silent failure.**

This one is learned the hard way, so learn it here instead. You set up self-push. It
works. You stop looking. Weeks later you discover a worker's push job died on day three —
credentials rotated, disk filled, a path moved — and it has persisted *nothing* since. The
data you thought was safe was never leaving the node. The backup failed silently, and
"silent" is the whole problem: a loud failure gets fixed the same day; a silent one is
discovered only when you reach for the data that isn't there.

The guard is the **dead-man's-switch**: the heartbeat file plus a watcher that *actively
complains when the heartbeat goes stale.* The mechanism that proves the backup is alive
has to be **push-based and monitored**, not pull-when-you-remember. Concretely:

- Every successful push advances a heartbeat timestamp.
- The hub's backstop checks each heartbeat against a threshold (e.g. "no push in 2×
  expected interval → alarm").
- A stale heartbeat pages a human / posts to a push-notification helper (e.g. Telegram or
  ntfy). Silence is not success; silence is the alarm.

The inversion that matters: don't ask "did the backup run?" (you'll forget to ask). Make
the *absence* of a fresh heartbeat generate a signal on its own. The system tells you it's
broken; you don't have to go checking.

## Failure modes & guards

| Failure mode | Symptom | Guard |
|---|---|---|
| **Store confusion** | Diary entries in the wiki; domain facts lost in session logs | Three stores, three jobs; classify before writing |
| **Lost node memory** | Session ends, insight gone | Worker self-push on a schedule |
| **Silent backup death** | Push job died weeks ago; nobody noticed | Heartbeat + staleness watcher (dead-man's-switch) |
| **Double-commit / clobber** | Two nodes fight over one path | One writer per path; hub read-only over worker subtrees |
| **Divergent conventions** | Each node invents its own naming/rules | Shared subtree, curated centrally via branch→review→merge |
| **Backstop-only reliance** | Hub pull is the *only* persistence path | Self-push primary, pull is the *backstop*, not the plan |
| **Stale episodic context** | Node re-learns preferences every session | Read the memory repo at session start |

## Minimal setup steps

1. **Three repos**: wiki (domain truth), memory (episodic), node-memory (per-node brains +
   `shared/` conventions).
2. **Partition writers by path**: `worker-a/`, `worker-b/`, `hub/`, `shared/`. Enforce
   "one writer per path" as a convention in the shared subtree.
3. **Wire worker self-push**: a scheduled job per worker that commits + pushes its own
   subtree and touches a heartbeat file.
4. **Wire the hub pull-backstop**: a scheduled job that pulls all subtrees and **checks
   every heartbeat for staleness**.
5. **Add the watcher**: stale heartbeat → notify a human via a push-notification helper.
   This is the dead-man's-switch; without it steps 3–4 are theater.
6. **Read at session start**: each node loads the memory repo (episodic) and its
   node-memory subtree before working, so it recovers context that isn't domain truth.

Three stores keep three kinds of memory honest. Self-push moves memory home; the
pull-backstop catches what self-push drops; the heartbeat watcher catches when the whole
scheme quietly stops. Build all three, or you've built a backup you'll trust right up until
the day you need it.
