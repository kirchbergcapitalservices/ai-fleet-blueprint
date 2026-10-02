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

**Two stores per node, not one.** An agent CLI keeps its memory under its *profile directory*. A node that runs an interactive profile for humans and a headless worker profile for jobs therefore has **two** memory stores that share almost nothing (on one of ours the overlap was a single index file). Backups that know only the worker's store silently miss everything the interactive sessions learned. Inventory every profile directory on every node before you wire a backup.

The node-memory split is worth dwelling on. `worker-a/` and `worker-b/` are private
brains — a node writes freely to its own subtree and never to another's. `shared/` holds
the conventions (naming, commit rules, boundaries) that bind the whole fleet. This gives
you node autonomy without divergence: nodes think independently but obey the same house
rules.

## Getting memory home: self-push + pull-backstop

A memory a node never persists is a memory that dies when the session does. Two mechanisms,
belt and suspenders, get memory off a node and into the shared repos.

**Worker self-push (primary).** Each worker is responsible for its own persistence:

- A scheduled job (e.g. every 6 h, example cadence) commits and pushes that node's
  memory subtree.
- A **verdict record** is written at every end — success *or* failure — with the verdict,
  the exit code and an expiry. A bare "touch on success" writes nothing when the job dies
  at a gate, and nothing looks exactly like "not due yet" ([06-watchdogs.md](06-watchdogs.md)).

**Hub pull-backstop (secondary).** The hub periodically pulls the repo, so a second copy of
every worker's subtree exists off the worker. It **reads**; it never writes into a worker's
subtree (one writer per subtree — next section). The hub also reads the workers' records —
but the *primary* staleness alarm does not live on the hub: the hub is the machine most
likely to be closed. It lives on an always-on node ([06-watchdogs.md](06-watchdogs.md)); the
hub's check is the second pair of eyes.

| Mechanism | Runs on | Frequency | Job |
|---|---|---|---|
| Self-push | each worker | e.g. every 6 h | Commit + push own subtree; write the verdict record |
| Verdict record | each worker | every run, every outcome | ok / fail + rc + expiry (`max_age_s`) — never a bare touch |
| Pull-backstop | hub | e.g. daily | Pull the repo; **read** records; second pair of eyes |
| Primary staleness alarm | an always-on node | every few minutes | expired or missing record → *unchecked*, then alarm |

## Two rules against the double-commit

With multiple writers and a pulling hub, the failure you must design out is the
**double-commit** — two actors committing the same change, or two actors writing the same
path and clobbering each other. It takes two rules, because the two races are different:

> **Across machines: every path has exactly one writer.**
> **Inside one clone: one writer at a time — the transaction lock.**

- Each node writes **only** its own subtree (`worker-a/` written only by `worker-a`). The
  hub pulls and reads everything and writes only the areas it owns. Concurrent pushes then
  touch disjoint files and rebase without conflict.
- Disjoint paths do **not** protect two sessions in the *same clone*: `rebase`, `commit` and
  `stash` act on the whole clone. Two helpers that each "only touch their files" still
  committed each other's staged work and lost each other's staging selection until every
  write went through one locked primitive ([04-multi-writer-git.md](04-multi-writer-git.md)).
- Shared conventions that *execute* (hooks, scripts, routines) go through branch → review by
  a different node → merge ([10-code-gates.md](10-code-gates.md)). Shared *prose* is written
  directly through the locked helper — a review gate on prose would stall the knowledge loop.

## The dead-man's-switch principle (a hard lesson)

> **A backup without a staleness watcher is not a backup. It's a future silent failure.**

This one is learned the hard way, so learn it here instead. You set up self-push. It
works. You stop looking. Weeks later you discover a worker's push job died on day three —
credentials rotated, disk filled, a path moved — and it has persisted *nothing* since. The
data you thought was safe was never leaving the node. The backup failed silently, and
"silent" is the whole problem: a loud failure gets fixed the same day; a silent one is
discovered only when you reach for the data that isn't there.

The guard is the **dead-man's-switch**: the verdict record plus a watcher that *actively
complains when the record expires or says fail.* The mechanism that proves the backup is alive
has to be **push-based and monitored**, not pull-when-you-remember. Concretely:

- Every run — success **or** failure — writes a verdict record with an expiry (`max_age_s`,
  about 2× the cadence). A bare "touch on success" writes nothing when the job dies at a gate,
  and nothing looks exactly like "not due yet".
- A watcher on an always-on node reads every record: expired or missing → **unchecked**,
  which is neither green nor red but a finding of its own; `fail` → red.
- Alerts fire on **state change** and go through one notification helper. A watcher that
  posts every run trains people to ignore it. Silence is not success; silence is the alarm.

The inversion that matters: don't ask "did the backup run?" (you'll forget to ask). Make
the *absence* of a fresh record generate a signal on its own. The system tells you it's
broken; you don't have to go checking.

## The context checkpoint: sessions end, knowledge does not

A fourth place knowledge gets lost is not a machine but a **session**. An agent session has a
finite context window; when it fills, the session either degrades (the agent "forgets" what
it decided an hour ago) or ends. If the session's working state lives only in that window, the
next session starts from zero — and re-derives, re-asks, re-decides.

We treat 80 % of the context budget as a hard checkpoint, enforced by a stop-hook, not by the
agent's good intentions:

| At 80 % | What happens |
|---|---|
| 1 | The hook blocks exactly once and hands the agent a fixed task: *write the checkpoint now, start nothing new.* |
| 2 | Wiki articles and the append-only log are brought up to date first — durable truth before anything else |
| 3 | A **handoff note** (`.handoff.md` — the template is in [templates/handoff-template.md](../templates/handoff-template.md)) is written: what was being done, what is decided, what is open, where the evidence is, which background jobs are still running |
| 4 | Commit + push. One line to the human. **Nothing new begins in this session.** |
| ≥ 92 % | Emergency mode: only the handoff note and the push |
| < 80 % | **Silence.** No warnings at 60 %, no nagging — an early warning trains the agent to ignore the real one |

The next session opens with the handoff note loaded. In practice this is the *more* effective
continuation, not a brake: a fresh context with a crisp state beats a saturated one that has
started to lose its own decisions.

Two conventions make the note useful rather than a diary: it carries **evidence pointers**
(commit SHAs, log lines, file paths), not prose summaries; and it distinguishes **threads** —
long-lived lines of work with their own handoff note — from **jobs**, one-off tasks that need
none. A job writing a handoff note is noise; a thread without one is amnesia.

## Failure modes & guards

| Failure mode | Symptom | Guard |
|---|---|---|
| **Store confusion** | Diary entries in the wiki; domain facts lost in session logs | Three stores, three jobs; classify before writing |
| **Lost node memory** | Session ends, insight gone | Worker self-push on a schedule |
| **Silent backup death** | Push job died weeks ago; nobody noticed | Verdict record with expiry + watcher on an always-on node (dead-man's-switch) |
| **Double-commit / clobber** | Two nodes fight over one path | One writer per path; hub read-only over worker subtrees |
| **Same-clone race** | Two sessions in one clone commit each other's staging | One locked write primitive per clone ([docs/04](04-multi-writer-git.md)) |
| **Second memory store unknown** | Interactive sessions' learnings never backed up | Inventory every profile directory; back up each |
| **Divergent conventions** | Each node invents its own naming/rules | Shared subtree, curated centrally via branch→review→merge |
| **Backstop-only reliance** | Hub pull is the *only* persistence path | Self-push primary, pull is the *backstop*, not the plan |
| **Context saturation** | Session degrades at the end; next session re-derives everything | Stop-hook checkpoint at 80 %: wiki + log → handoff note with evidence pointers → push → stop |
| **Stale episodic context** | Node re-learns preferences every session | Read the memory repo at session start |

## Minimal setup steps

1. **Three repos**: wiki (domain truth), memory (episodic), node-memory (per-node brains +
   `shared/` conventions).
2. **Partition writers by path**: `worker-a/`, `worker-b/`, `hub/`, `shared/`. Enforce
   "one writer per path" as a convention in the shared subtree.
3. **Wire worker self-push**: a scheduled job per worker that commits + pushes its own
   subtree and writes its verdict record (every outcome, with expiry).
4. **Wire the hub pull-backstop**: a scheduled job that pulls all subtrees and **checks
   every record for expiry or failure**.
5. **Add the watcher** on an always-on node: expired or missing record → *unchecked*, `fail` → red; notify on state change via one notification helper.
   This is the dead-man's-switch; without it steps 3–4 are theater.
6. **Read at session start**: each node loads the memory repo (episodic) and its
   node-memory subtree before working, so it recovers context that isn't domain truth.

Three stores keep three kinds of memory honest. Self-push moves memory home; the
pull-backstop catches what self-push drops; the record watcher catches when the whole
scheme quietly stops. Build all three, or you've built a backup you'll trust right up until
the day you need it.
