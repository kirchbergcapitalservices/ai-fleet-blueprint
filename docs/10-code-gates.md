# 10 — Code goes live on merge: the gates around executable change

In a fleet, a script merged to `main` is **deployed** — every node pulls `main` on a timer
(see [docs/04](04-multi-writer-git.md)). There is no staging environment between "merged" and
"running on three machines at 3 a.m." That changes what a pull request is: not a courtesy, but
the only moment where a second pair of eyes can stop a bad change before it runs everywhere.

This chapter describes the gates we put around executable change after a merge with two open
review findings went live and broke the nightly jobs on two nodes. Everything here is cheap. All
of it is boring. That is the point.

## What needs a gate — and what deliberately does not

| Path class | PR required | Who merges | Why |
|---|---|---|---|
| scripts, hooks, routines, anything a node *executes* | **yes** | **a different node than the author** | merge = deploy; the author has already convinced themselves |
| the agent's own instruction file (`CLAUDE.md`-style) | yes | a different node | it steers every future session on every node |
| wiki articles, the append-only log, the index, handoff notes | **no** — multi-writer stays | — | 100+ commits a day from three writers; a gate here would stall the knowledge loop |

**The content is not protected. The code is.** Protecting `main` wholesale would kill the
multi-writer wiki that makes the fleet useful. So the gate is scoped to *paths*, enforced by a
versioned `pre-push` hook (code paths cannot reach `origin/main` except through a merge on the
server) and, on repos where the whole repo is code, by branch protection with `enforce_admins`.

## Gate 1 — a different node merges

In a small fleet every node typically pushes under **one GitHub identity**, so GitHub
cannot tell the author from the reviewer. The rule therefore lives in the process, not in a
server setting: **the author never merges their own PR.** The review request travels through the
fleet inbox (next section), the reviewer node runs the checks, posts the verdict, and merges with
`--match-head-commit <sha>` so a late push cannot slip in under an approval.

Why not "the hub merges everything"? Because the hub laptop is on a plane half the time, and
because a hub-only merge is a *node* gate — it says who, not what was checked. The point of the
gate is the independent check, and any node can do that. (Rule from [docs/01](01-architecture.md):
peer-symmetric beats hub-centric.)

Measured effect in our own history: in the first two weeks of the rule, foreign review caught
three defects the author had not seen — twice a missing positive control in a test, once a
hook that would have blocked all commits on a sibling repo.

## Gate 2 — a second *model* reviews the exact commit

A second model family (a code-review CLI run in a sandbox) reviews the **head SHA** that will be
merged. Not "the PR", not "the branch" — the SHA. A new commit invalidates the review. The reviewer
node posts one machine-readable line as a PR comment before merging:

```
reviewed-by-second-model <sha12>, run <run-id>, verdict <OK|BLOCK>, note <free text>
```

| Rule | Why |
|---|---|
| comment, not PR body | a watcher script reads comments and reviews; the body can be edited silently |
| verdict bound to `sha12` | a review of an older head is not a review |
| `BLOCK` must say for each P1: *pre-existing* (reproduced on the merge-base) or *introduced* | a pre-existing defect gets a follow-up task; an introduced one blocks; making a pre-existing defect newly reachable counts as introduced |
| a bot's auto-review does not count | the gate is a *deliberate* run by the reviewer node with the full repo context |
| docs-only PRs skip this gate | README, wiki text, comments without code |

The run log stays on the reviewer node (hash-chained, see [docs/09](09-second-engine-broker.md));
the comment is a **pointer, not a proof**. The real protection is still Gate 1 — the foreign
merge. Gate 2 adds a reviewer that does not share the author's blind spots *or* the human
reviewer's.

## Gate 3 — the fleet inbox: review requests as git objects

Nodes cannot always reach each other over SSH (the hub is often offline; workers sit behind NAT).
What every node *can* reach is the shared `node-memory` repo, pulled and pushed every 15 minutes
anyway. So the inbox is a directory convention, not a service:

```
node-memory/
  inbox/<node>/<id>.task            open — waits for that node's consumer
  inbox/<node>/running/<id>.task    claimed (a `git mv`) — exactly one consumer per node
  done/<node>/<id>.md               result; first lines carry VERDICT: DONE|PARTIAL|BLOCKED|FAILED
```

| Property | How it falls out of git |
|---|---|
| a task is a commit | atomic, attributable, replayable |
| a claim is a rename | the audit trail of who took it when; exclusion comes from **one consumer process per node inbox** (a local lock) — two identical renames from two clones would *not* conflict in git |
| a result is a file | the requester finds it on its next pull, no callback needed |
| disjoint paths per node | no merge conflicts between nodes |

The first non-empty line of a task is its **route** (`review: …`, `ops: …`), so a node's consumer
can dispatch without parsing prose. The sender refuses oversized tasks and anything that matches
the patterns of your confidential-data class — this repo is the *non-sensitive* bridge; anything
confidential takes a node-local lane that never leaves the machine.

## Gate 4 — the watcher that counts what was skipped

A rule that is only text decays. A small daily script lists merged PRs on code paths and checks:
was there a review comment from a *different* node? Does it carry a verdict line bound to the
merged SHA? Anything missing is reported — never fixed — on the fleet's notification channel.

Two design rules for the watcher, both learned by getting them wrong:

- **Watchers report, they never clean up.** A watcher that reverts, re-opens or deletes is an
  automation with a destructive branch and no human in the loop.
- **Compare against the source, not against a sibling copy.** Our first drift check compared
  one derived list with another derived list that lived on no node together — it could
  structurally never see anything. Check derived state against the thing it was derived from.

## Emergency bypass — allowed, logged, reviewed

Sometimes the gate itself is what is broken. A bypass exists (`PUSH_BYPASS=1` for the hook,
a short lift of branch protection for the server gate), with three conditions that are not
optional: it is **logged** in the append-only log under a fixed marker, a **review task** for
the bypassed change is filed in the inbox within 24 hours, and the bypass is **never scripted**.
A bypass nobody has to write down is a gate nobody has to pass.

## Failure modes & guards

| Failure mode | Guard |
|---|---|
| merge = deploy, defect goes live on every node | PR + foreign-node merge on executable paths; content paths stay free |
| one GitHub identity for all nodes — GitHub cannot enforce "someone else" | process rule + watcher that reads the review trail |
| review of a stale head | verdict line bound to `sha12`; merge with `--match-head-commit` |
| reviewer rubber-stamps because the author "already tested" | second-model review with the whole repo as context; author's test log is input, not proof |
| review requests get lost between machines that cannot reach each other | inbox as git objects in the repo everyone already syncs |
| the rule erodes silently | daily watcher, report-only, Telegram-style channel |
| gate blocks the fix for the gate | documented bypass with log marker + 24 h review task |
| "the hub merges" becomes a bottleneck and a single point of failure | any non-author node may merge — gate on the *action*, not the *node* |

## Minimal setup steps

1. Decide the **path classes** for each shared repo: which paths execute, which are content.
   Write the table into the repo's `CLAUDE.md`-style file so every agent session sees it.
2. Install a versioned `pre-push` hook that rejects pushes to `origin/main` touching code paths
   (branches always pass). Keep the hook in the repo and install it with a script — a file in
   `.git/hooks` is never cloned.
3. For repos that are all code, turn on branch protection with `enforce_admins`.
4. Create the inbox directories in `node-memory` and a 20-line `send` / `claim` / `done` script.
5. Give the reviewer node a one-command second-model review (see [docs/09](09-second-engine-broker.md))
   and the exact comment format above.
6. Add the daily watcher; make it report-only from day one.
7. Write the bypass procedure down **before** you need it, including the log marker.
