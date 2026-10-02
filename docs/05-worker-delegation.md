# 05 — Delegating to CLI workers

> A fleet is an org chart made of processes — but the org chart is about *roles*, not
> about machines. Most delegation failures are not model failures — they're brief failures
> and wiring failures. This chapter is about getting both right.

## Roles are assignable; gates belong to actions

v1 of this chapter drew a department-head model: the laptop decomposes, reviews and owns;
workers produce and never publish. We replaced that model one day before v1 shipped and
did not notice. What it got wrong is subtle and expensive:

| v1 said | What broke | v2 rule |
|---|---|---|
| "the hub curates, workers do not publish" | the laptop became a bottleneck and a single point of failure — nothing left the fleet while it was on a plane | **Any node may write to any shared system**, autonomously and headless. The heavy always-on node is often the owner of a thread; the laptop contributes |
| safety came from *which node* did a thing | a node gate says *who*, not *what was checked*; it also quietly exempted the laptop from the checks | **Gates sit on actions, not nodes:** sending in the operator's name, publishing, filing, force-pushing, changing security posture — each needs a *human* sign-off, and the same gate applies on every node including the laptop |
| the hub reviews everything a worker produces | the author's node reviewing is still the author reviewing | executable change is merged by **a different node** than its author, with a second model bound to the exact commit ([docs/10](10-code-gates.md)) |

Headless jobs cannot ask for a sign-off at 03:00. They run under **pre-recorded grants**:
a human writes the grant for a specific action class (say, "send the weekly digest to
this list") *before* the job exists; the job checks the grant file and refuses without it.
Self-granting is forbidden by construction (the grant lives where the worker user cannot
write). The gate list is **closed**: a job escalates only at listed gates, not for ordinary
work — "when in doubt, ask" applied to everything makes an autonomous worker useless.

The design question for every write is therefore *"which action gate does this need?"*,
never *"which node is allowed?"*. And the counter-duty of autonomy is **sync**: whoever
writes, pushes, logs and makes the change visible to the others. Autonomy without sync is
drift.

## The helper pattern

Delegation is a thin wrapper around "run the CLI agent on a remote box, under a specific
config profile." The moving parts:

| Part | What it is | Why it matters |
|---|---|---|
| Transport | `ssh` to the worker host | Runs the agent where the worker's tools/data live |
| Profile | A per-worker config dir (via a `CLAUDE_CONFIG_DIR`-style env var) | Isolates each worker's identity, memory subtree, and settings |
| Subscription | A separate model subscription per worker | Independent rate limits; one worker's load doesn't starve another |
| Mode | foreground / background / `-f` file-brief | Match interaction to task length |

**Run modes:**

| Mode | Use when | Behavior |
|---|---|---|
| Foreground | Short task, you want the result now | Blocks; output streams back |
| Background | Long task, you'll collect later | Detaches on the *hub* side; poll or get notified on completion |
| `-f` (file brief) | The brief is long or structured | Pass the brief as a file, not an inline string — no quoting hell, reproducible |

A minimal helper is just: `ssh <worker-host> 'CLAUDE_CONFIG_DIR=<profile> <agent-cli> <mode> <brief>'`.
Everything hard is in the brief and the profile, not the transport.

**The headless iron rule.** "Background" above is about the hub's shell. *Inside* the
worker, a headless agent turn (`<agent-cli> -p …`) ends when the agent's answer ends — and
**every background process the agent started dies with it.** Twice we lost long builds this
way before writing it down. Anything inside a headless turn that must outlive the turn is
started with `nohup … &` (and the system's sleep-prevention helper), writes its own record,
and is collected by a later turn. Never an agent "background task" inside a headless run.

## Brief discipline

A worker is only as good as its brief. A vague brief gets a vague, confident, wrong answer.
Every brief has five parts, in order:

| Part | Contains | Failure if omitted |
|---|---|---|
| **1. Context** | What this is, why it matters, what's already true | Worker re-derives (badly) or invents context |
| **2. Exact numbered tasks** | `1.`, `2.`, `3.` — atomic, orderable, checkable | Worker guesses scope; does too much or too little |
| **3. Report format** | The exact shape of the expected output | You get prose when you needed a table; can't diff runs |
| **4. Hard DON'Ts** | Explicit prohibitions — what NOT to touch, do, or assume | Worker "helpfully" wanders into damage |
| **5. Selfcheck** | How the worker verifies its own output before reporting | Errors surface at review instead of at the source |

**Numbered tasks** beat prose paragraphs because they're checkable: the worker can report
"1: OK, 2: OK, 3: blocked because…" and you can diff that against the brief line by line.

**The hard DON'Ts list is not optional.** It's the guardrail that keeps an eager agent
inside its lane. Examples of good DON'Ts: "don't touch any repo other than the listed one,"
"don't quote real operational data," "don't invent facts you can't source." But be exact
about what it is: **the DON'Ts bound the agent's *scope*; enforcement bounds the *damage*.**
A brief is read by a probabilistic actor and can be misread, ignored or injected around.
What makes a worker safe to run unattended is the unprivileged user, the CLI deny-list and
the sandbox ([docs/07](07-security.md)) — the brief makes it *useful*.

**Contract numbering.** Give every requirement a stable id (`REQ-1 … REQ-n`) and every
explicit non-goal one too (`NG-1 … NG-n`), and never renumber. The worker's report is then a
**scope ledger**: one line per REQ with PASS / FAIL / UNTESTED (+ why), one line per NG
confirming it was left alone, the sentence `Other behavior changes: None` — and, for anything
that was written, the **commit hash**. Evidence without a hash is decoration. A worker that
finds a REQ it can only meet by violating an NG reports the conflict instead of choosing;
a fix that widens the contract until the test passes is the same failure as an agent that
widens the spec.

**Define "done" as delivered.** Done is not "I wrote the files". Done is: committed, pushed,
the hash in the ledger — and the requester **verifies at the receiving end** (its own pull,
its own file count), never by the sender's word. "There is no auto-pull" is a sentence we
now put in every brief.

## Why NO sudo on workers

Workers run **without elevated privileges. Ever.** Not as a nicety — as a containment
boundary.

- An agent is a probabilistic actor executing generated commands. The blast radius of a
  mistake must be bounded by construction, not by the agent's good judgment.
- Without sudo, the worst a confused or misdirected worker can do is scoped to an
  unprivileged user's files. With sudo, "clean up temp files" can become an
  un-recoverable system event.
- Least privilege also makes reasoning tractable: you can enumerate what a non-privileged
  worker *can* touch. You cannot enumerate what a root worker might touch.

If a task genuinely needs elevation, that's a signal to redesign the task or hand it to a
human — not to hand root to an autonomous loop.

## The wrong-user trap

Here's one learned the hard way. You wire a worker assuming it runs as user `X`. You set
paths, permissions, and config for `X`. It actually runs as `Y` — a different login, a
different home directory, a different config profile. Now the worker writes to the wrong
home, reads a config that isn't there, pushes memory to the wrong subtree, and every
symptom points somewhere other than the cause. You debug the brief for an hour before
realizing the *identity* was wrong the whole time.

The guard is one command, run **before** wiring anything:

> **Verify the worker user empirically. Don't assume it — ask the box.**

`ssh <worker-host> 'whoami; echo $HOME; pwd'` and read the actual answer. Wire paths,
profiles, and permissions to *that* user, not the one you expected. Assumptions about
identity are the most expensive kind because every downstream symptom lies about the root
cause.

## Prose is written directly; code goes through a branch

v1 sent *everything* shared through branch → PR → hub merge. That contradicted its own
architecture chapter ("all nodes read-write") and, in practice, stalled the knowledge loop:
a wiki article that waits a day for a merge is an article the next session answers without.
The split that holds:

| What a worker changes | Path | Why |
|---|---|---|
| **Prose**: wiki articles, the append-only log, the index, its own node-memory subtree | **direct write** through the locked helper ([docs/04](04-multi-writer-git.md)) | a hundred small writes a day; the lock and `commit --only` make them safe; a review gate here costs more than it catches |
| **Executable change**: scripts, hooks, routines, shared agent instructions | **branch → PR → a *different node* merges**, second-model review bound to the commit | merge is deploy; the author has already convinced themselves ([docs/10](10-code-gates.md)) |

Two guards that belong here because they are delegation failures, not git failures:

- **Lock per task id before a worker starts.** The same brief once ran three times in
  parallel because three consumers picked it up within a minute. A task is claimed by a
  rename in the inbox (next section) or by a lock keyed on the task id — never by "I'll
  probably be the only one".
- **Verify delivery at the endpoint.** The requester pulls and counts; the worker's "done"
  is a claim.

## The fleet inbox: delegation when SSH is not there

The helper above needs the hub to reach the worker over SSH at the moment of delegation. Often it
cannot — the hub is asleep, travelling, or the worker needs to hand something *back* to a hub that
is behind NAT. The durable channel is the repo every node already pulls and pushes on a timer:
`node-memory`, with one inbox directory per node (layout, routes and the claim-by-rename mechanic in
[docs/10](10-code-gates.md)). A task is a commit; a result is a file under `done/<node>/`. Review
requests for pull requests travel the same way, which is what makes "a different node merges"
workable without a human relaying messages.

Keep the brief discipline identical: the task file *is* the brief — context, numbered tasks, report
format, DON'Ts — and the first line is the route so the consumer can dispatch without reading prose.

## Failure modes & guards

| Failure mode | Symptom | Guard |
|---|---|---|
| **Vague brief** | Confident, off-scope, wrong output | Five-part brief; exact numbered tasks |
| **Wandering agent** | Worker "helpfully" touches things it shouldn't | Hard DON'Ts list, explicit and tight |
| **Unbounded blast radius** | One bad command does system-level damage | No sudo on workers, ever |
| **Wrong-user wiring** | Paths/config/memory all land in the wrong place | Verify `whoami`/`$HOME` empirically before wiring |
| **Unreviewed executable change goes live** | A script merged by its author runs on every node | PR + a different node merges; second-model review on the commit |
| **Node gate instead of action gate** | Laptop is a bottleneck *and* exempt from checks | Gates on actions, valid on every node; pre-recorded grants for headless sends |
| **Format drift** | Can't compare or diff worker runs | REQ/NG ids + scope ledger with commit hash |
| **Quoting hell** | Long inline brief breaks on shell escaping | Use the `-f` file-brief mode |
| **Silent worker** | Long background job, no signal on done/failed | Verdict record + completion notification; requester verifies at the endpoint |
| **Background work dies with the turn** | Build vanishes when the headless answer ends | headless iron rule: `nohup`, own record, collect later |
| **Double dispatch** | One brief runs three times | claim by rename / lock per task id |
| **"Done" that was never delivered** | Files written, never pushed; hub reads stale state | done = pushed + hash in the ledger, verified by the receiver's own pull |

## Minimal setup steps

1. **One profile per worker**: a dedicated config dir and a separate model subscription so
   workers are isolated and independently rate-limited.
2. **Verify identity first**: `ssh <worker-host> 'whoami; echo $HOME'` — wire everything to
   the *actual* user.
3. **Confirm no sudo**: workers run unprivileged; convince yourself of the blast-radius
   bound before delegating anything.
4. **Write the helper**: `ssh` + profile env var + mode (foreground / background / `-f`).
5. **Template the brief**: context → numbered tasks → report format → hard DON'Ts →
   selfcheck. Reuse it for every delegation.
6. **Split prose from code**: prose is written directly through the locked helper; executable
   change goes branch → PR → merge by a different node. Write the closed **action-gate list**
   and the **grant files** for headless sends.
7. **Teach the headless iron rule** and the task-id lock in every worker's instruction file.

Delegation works when the roles are real and the gates are on the right thing: any node may
think and write, the dangerous *actions* wait for a human, and the boundary between them —
privileges, identity, review — is wired deliberately rather than assumed.
