# 05 — Delegating to CLI workers

> A fleet is an org chart made of processes. The `hub` is the department head: it curates,
> reviews, and owns the final artifact. The workers are the department: they execute
> well-scoped briefs and report back. Most delegation failures are not model failures —
> they're brief failures and wiring failures. This chapter is about getting both right.

## The department-head model

Draw the analogy explicitly, because it dictates every rule below.

| Org concept | Fleet concept | Responsibility |
|---|---|---|
| Department head | `hub` (orchestrator, on the laptop) | Decompose work, write briefs, review output, own the final version |
| Team member | `worker-a` / `worker-b` (CLI on a box) | Execute a scoped brief, report in the requested format, stay in lane |
| Deliverable | The curated artifact | Assembled and signed off by the hub, not shipped raw by a worker |

Workers do not publish. They produce; the hub curates and decides. This keeps a single
throat to choke for quality and a single boundary check before anything leaves the fleet.

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
| Background | Long task, you'll collect later | Detaches; poll or get notified on completion |
| `-f` (file brief) | The brief is long or structured | Pass the brief as a file, not an inline string — no quoting hell, reproducible |

A minimal helper is just: `ssh <worker-host> 'CLAUDE_CONFIG_DIR=<profile> <agent-cli> <mode> <brief>'`.
Everything hard is in the brief and the profile, not the transport.

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
inside its lane. Examples of good DON'Ts: "don't commit or push anything," "don't touch
any repo — only write files under this folder," "don't quote real operational data,"
"don't invent facts you can't source." A worker that respects a tight DON'Ts list is safe
to run unattended; one without it is a liability.

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

## Branch-then-PR for curated resources

When workers contribute to a **shared, curated resource** (the wiki, shared conventions,
anything the whole fleet reads), they do not write to the canonical version directly. They
propose; the hub disposes.

| Step | Actor | Action |
|---|---|---|
| 1 | worker | Do the work on a **branch** (namespaced to the worker, e.g. `worker-a/<topic>`) |
| 2 | worker | Open a PR / change request; report it back to the hub |
| 3 | hub | Review — quality, boundary, correctness |
| 4 | hub | Merge to canonical (or bounce back with notes) |

This is the department-head model made concrete: workers execute onto branches, the hub
reviews and owns the merge. The canonical resource never contains unreviewed worker output.
For a worker's *own private* scratch (its node-memory subtree), direct writes are fine —
the branch-then-PR ceremony is specifically for shared, curated things.

## Failure modes & guards

| Failure mode | Symptom | Guard |
|---|---|---|
| **Vague brief** | Confident, off-scope, wrong output | Five-part brief; exact numbered tasks |
| **Wandering agent** | Worker "helpfully" touches things it shouldn't | Hard DON'Ts list, explicit and tight |
| **Unbounded blast radius** | One bad command does system-level damage | No sudo on workers, ever |
| **Wrong-user wiring** | Paths/config/memory all land in the wrong place | Verify `whoami`/`$HOME` empirically before wiring |
| **Unreviewed writes to shared truth** | Canonical wiki contains raw, unvetted worker output | Branch-then-PR; hub owns the merge |
| **Format drift** | Can't compare or diff worker runs | Mandate an exact report format in the brief |
| **Quoting hell** | Long inline brief breaks on shell escaping | Use the `-f` file-brief mode |
| **Silent worker** | Long background job, no signal on done/failed | Report format + completion notification |

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
6. **Set the curation flow**: workers branch + PR into shared resources; the hub reviews
   and merges. Private scratch can be written directly.

Delegation works when the org chart is real: the hub thinks and owns, the workers execute
in a bounded lane, and the boundary between them — privileges, identity, review — is wired
deliberately rather than assumed. Get the brief and the wiring right and the model does the
rest.
