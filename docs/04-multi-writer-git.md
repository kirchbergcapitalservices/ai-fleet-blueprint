# 04 — Multi-Writer Git as the Fleet Nervous System

Three machines, several long-running agents, one shared body of knowledge. The
hard part is not the AI — it is keeping three writers from stepping on each
other. Our answer is boring on purpose: **git is the only nervous system, and a
git remote is the only hub.** Nodes never talk to each other directly. They talk
to a remote, and the remote fans state back out.

This chapter is the coordination layer everything else in the fleet stands on.
It was the chapter with the most corrections in v2 — see "What v1 got wrong"
at the end; the scripts in [`scripts/`](../scripts/) and the harness in
[`tests/harness.sh`](../tests/harness.sh) are the v2 mechanics.

## The one rule: hub-and-spoke, never node-to-node

```
        ┌───────────┐
        │  remote   │   ← the ONLY meeting point (GitHub by default)
        └─────┬─────┘
   push/pull  │  push/pull
   ┌──────────┼──────────┐
   │          │          │
┌──▼──┐   ┌───▼────┐  ┌───▼────┐
│ hub │   │worker-a│  │worker-b│
└─────┘   └────────┘  └────────┘
     (no direct arrows between nodes)
```

We deliberately never let one node SSH into another to copy files. Direct
node-to-node sync feels faster but it has no audit trail, no conflict handling,
and no single source of truth — you get three slightly different copies and no
way to say which is right. Routing everything through a git remote gives us
history, atomic conflict detection, and a place to reason about "what is true."

| Anti-pattern (banned)            | What we do instead                         |
| -------------------------------- | ------------------------------------------ |
| `scp file worker-a:/…`           | commit + push; the other node pulls        |
| `rsync` between nodes            | shared repo, fetch + rebase                |
| "just edit it live on both"      | one writer at a time, push immediately     |
| shared network drive as truth    | git history is truth; disk is a cache      |

**The one exception, and it is still hub-and-spoke:** if you hold data that must never
reach a cloud host, give it an **in-network bare repository on one always-on node** as its
`origin` — with a server-side `pre-receive` hook that can hold a push and a push
log. The topology is unchanged (every node talks to *one* remote); only the remote
moved into the house. What stays banned is node-to-node copying.

## Canonical git identity everywhere — and a provenance trailer

Every node — and every agent on every node — commits as the **same, fixed
identity**, set once at the system level, not left to the agent:

```bash
git config --global user.name  "fleet-bot"
git config --global user.email "fleet-bot@users.noreply.github.com"
```

An agent left to its own devices will *invent* an identity from the environment —
`root`, a hostname, a half-hallucinated name. That pollutes `git blame`, breaks
signed-commit rules, and once put a stranger's account id into our commits. **Never
let an agent choose its own identity.**

The flip side: with one identity for all nodes, the author field proves *nothing*
about **which machine** acted — and "a different node merges" ([docs/10](10-code-gates.md))
needs exactly that. So the origin node is recorded, **mandatorily**, where the
identity cannot carry it:

```
wiki: add kestrel retry-policy note

origin-node: worker-b
```

and every review or merge leaves a comment naming the node that checked. Treat the
trailer as part of the commit, not as decoration.

## Pull before edit, push immediately

The whole discipline collapses to two habits, drilled into every agent's routine
and enforced by wrappers:

1. **Pull before you edit.** Never start from a stale tree.
2. **Push immediately after you commit.** A commit sitting unpushed for an hour is
   a landmine for the next writer.

One deliberate exception: the log appender writes its entry *first* and lets the helper
fetch and rebase afterwards — both under the clone's transaction lock, with the log declared
`merge=union`. A fetch before the append would change no outcome for an append-only file and
would double the round trips; a conflict leaves the entry committed locally, and a re-run is
idempotent.

| Step        | Command                                             | Why                                              |
| ----------- | --------------------------------------------------- | ------------------------------------------------ |
| before edit | fetch with an **explicit refspec**, then rebase/ff onto the tracking ref | `git pull` reads the clone-wide `.git/FETCH_HEAD`, which any parallel `git fetch` in the same clone rewrites ("cannot rebase onto multiple branches") |
| after edit  | `git add <specific files>`                          | stage only what you touched                      |
| commit      | `git commit --only -m "scope: msg" -- <those files>` | **commit only your paths** — see below           |
| publish     | safe-push (below)                                   | get it off the local machine now                 |

## Safe-push: the write primitive

A naive `git push` fails the moment someone else pushed first. A naive
`push --force` "fixes" that by destroying their work. Both are wrong. The wrapper
[`scripts/git-safe-commit-push.sh`](../scripts/git-safe-commit-push.sh) is the only
way automation writes to a shared repo. What it does, in order, and why each step
exists:

| Step | Mechanic | The failure it closes |
|---|---|---|
| 1 | takes the clone's **transaction lock** (next section) | two sessions in one clone interleave rebase and commit |
| 2 | `git commit --only -- <paths>` | **`git commit -m` takes the whole index** — a parallel session's staged files were committed and pushed under your message (v1 did this, measured) |
| 3 | verifies every file in the new commit lies under a named path | a wrong pathspec silently widens the commit |
| 4 | `git fetch origin +refs/heads/main:refs/remotes/origin/main` | `git pull` and the shared `FETCH_HEAD` |
| 5 | sets the other session's uncommitted work aside with its **own stash entry, index included**; rebases; `stash apply --index` | `--autostash` restores *without* the index (the other session's staging selection is lost) and a failed autostash pop still exits 0 |
| 6 | pushes with bounded retries; a rebase **conflict aborts** — nothing overwritten, the commit stays local, a human resolves | the race that `--force` "fixes" by destroying work |
| 7 | re-fetches and checks the pushed commit is on the remote branch | plain `git push` updates the tracking ref itself, so without the re-fetch a success check can never fail |

Its exit codes are part of the contract — callers and watchers act on them:
`4` conflict (nothing overwritten, commit local) · `5` not pushed (commit local;
re-running pushes it — "nothing new to commit" is not "done" while a local commit sits
unpushed) · `6` another session's work was left in `git stash list` — **pushed or not** (the message says
which); a human looks at both the stash and the remote before the next writer stashes again · `8` *unchecked* — either pushed but the endpoint re-check could not run, or nothing new was
staged and the remote could not be fetched to tell whether a commit is pending; never recorded as
ok, and the recovery is to *look* (`git fetch`, `git log origin/main..HEAD`), not to re-run blindly ·
`3` lock busy.

There is no `--force` anywhere in the fleet's automated paths.

## The transaction lock: one clone, one writer at a time

The remote handles cross-node races. Two agent sessions on the *same* machine, in
the *same* clone, are a different problem: rebase, commit and stash act on the whole
clone, not on "your" files. Disjoint paths do not protect you inside one clone.

v1 of this repo used a lock **file** (`.sync-lock`, created with `noclobber`, cleaned
up when "the holder PID is dead or the file is older than 5 minutes"). An independent
audit of our live setup found what every lock file eventually teaches: a lock whose
release depends on *derived* evidence can be wrong.

| v1 rule | What actually happened |
|---|---|
| "holder PID dead → lock is free" | `kill -9` of the script leaves its `git push` child running; a second writer starts while the first still writes (reproduced in `tests/harness.sh`, T5 control) |
| "older than 5 min → stale" | a slow push over five minutes had its lock stolen |
| "clean it up" | check-then-delete is never atomic; two cleaners, one deleted the lock the other had just taken |
| "the watcher skips while the file exists" | a marker left by a killed writer made the hygiene watcher skip that repo **forever**, silently |

v2 uses a **kernel lock**: `flock(2)` on `<git-dir>/repo-lock.flock`, taken by the
helper and **held for the whole transaction**. The lock belongs to the open file
description: git children inherit it and keep holding it until *they* finish — even
after `kill -9` of the parent — and the kernel releases it when the last holder exits.
There is no stale state, so nothing to clean, no PID question, no age rule, and no
eviction, ever. A holder that truly hangs is ended by a human; `lsof <git-dir>/repo-lock.flock`
lists every holder including children.

```bash
# scripts/lib/repo-lock.sh — source it, then:
repo_lock_acquire "$repo" "safe-push kestrel"   # waits REPO_LOCK_WAIT_S (90 s), rc 2 if busy
# … fetch → commit --only → rebase → push → verify …
# no release call: the kernel releases when the last holder exits
```

macOS ships no `flock(1)` command, which is why v1 reached for a lock file. The lib
opens the lock file on a bash file descriptor and lets a short `perl` call run
`flock(2)` on that inherited descriptor; the lock survives perl's exit because bash
still holds the description. On Linux `flock(1)` is used when present — same fd, same
semantics. A marker `<git-dir>/repo-lock.holder` carries `PID|epoch|description` **for
humans only**; it has no locking effect and lives inside the git dir, never in the
working tree.

| Mechanism | Guards against | Scope |
|---|---|---|
| transaction lock (`flock`, inherited) | two sessions changing HEAD/index/tree of one clone at once | one repository, **all its linked worktrees** (the lock lives in the common git dir — worktrees share the stash list and the object store) |
| versioned pre-commit guard | a *direct* `git commit` while a helper holds the lock | one clone |
| safe-push rebase + retry | two nodes pushing to the remote | whole fleet |

**Direct commits.** Not every write goes through a helper; a human or an agent types
`git commit`. The versioned hook [`scripts/hooks/pre-commit`](../scripts/hooks/pre-commit)
takes the same lock: a helper's child commit inherits the lock and passes straight
through; a direct commit takes the lock and hands it to a small keeper process that holds
it until the git process ends; a busy lock prints `⛔ COMMIT BLOCKED` with the holder and
exits 1. `--no-verify` bypasses all of this — never in automation. **Scope, stated
precisely:** the whole-transaction, kernel-inherited guarantee belongs to transactions started
by a *helper* (git runs as its child and inherits the lock). The hook gives a *direct* commit a
weaker, best-effort version — a keeper process holds the lock while the git process lives, and
if the keeper dies the lock is released early. Automation uses the helpers; direct commits are
the human convenience path.

**Hooks are not cloned.** A file in `.git/hooks` exists in exactly one clone; every other
clone silently runs without it while the docs still call it a gate. The hooks here are
*versioned* in the repo and **symlinked** in by [`scripts/hooks/install.sh`](../scripts/hooks/install.sh);
`install.sh --check` from a scheduled job reports a dangling link, a non-executable
target, a foreign hook or a redirected `core.hooksPath` — git itself complains about none
of these. A barrier whose presence you cannot check is an assumption.

## Commit only your paths

The nastiest bug we hit early: an agent runs `git add -A`, and a *parallel* session's
half-finished edits got swept into the wrong commit. v1 fixed the `add`: explicit file
lists, never `-A`, never `.`. v1 then ran `git commit -m` — **and `git commit` commits
the whole index**, including whatever the parallel session had staged. The sweep had
moved one command to the right; the header claimed the class was eliminated.

```bash
git add -- wiki/notes/kestrel.md log.md
git commit --only -m "wiki: kestrel note" -- wiki/notes/kestrel.md log.md
# then verify: git show --name-only --format= HEAD  ⊆  the named paths
```

The helper does both and refuses to run without a path list (`tests/harness.sh` T9:
a foreign staged file stays staged, stays local, and is not in the commit).

## Hourly git-hygiene watcher

A scheduled job on each node checks every shared clone it finds, under the same
transaction lock, and acts on exactly one unambiguous case:

| Repo state | Watcher action |
|---|---|
| clean + behind remote | fast-forward (`fetch` with refspec, then `merge --ff-only` onto the tracking ref) |
| clean + ahead + **not** behind | **push** — the one case where pushing cannot clobber anyone |
| clean + up to date | nothing |
| dirty (uncommitted, incl. untracked) | **alert** — a human decides |
| ahead **and** behind, or non-ff | **alert** — someone diverged |
| lock busy | skip and **count**; alert after 3 skips in a row |
| fetch failed | **alert** — "could not look" never reads as "fine" |

v1 taught "never auto-push". We held that line until a node accumulated 49 commits
that existed on no remote, the oldest five weeks old, on a repo nobody looked at.
Pushing the *unambiguous* case (clean, ahead, not behind) cannot overwrite another
writer's work; refusing it only moves the risk from "published too early" to "lost
with the disk". Everything ambiguous still goes to a human.

Two more rules from running it: **discover clones instead of maintaining a list** (a
hardcoded list was fail-open — the repos that mattered were the ones nobody added), and
**let a repo opt out of pulls where a pull is a deploy** (a service that restarts on
file change should be updated deliberately, not by the hygiene job at :17).

## A runtime clone is not a workbench

A clone that a service runs from, or that a deploy reads from, **stays on `main`** —
always. Build on a branch in a separate `git worktree`. We learned this when a session
checked out a feature branch in a runtime clone to test something, the deploy job ran
on schedule and installed the untested branch on two nodes. The reverse trap is as real:
a branch that happens to match the *old* deployed state reports a false green.

Corollary — **deployed is not durable.** A copy in `~/bin` drifts from the repo the
moment someone edits it in place. Keep a deploy manifest (path → repo file) and let a
scheduled check compare `sha256` of every deployed copy against the repo; a mismatch is a
finding, not a cleanup.

## Failure modes & guards

| Failure mode | Guard |
|---|---|
| Two nodes push at once → one rejected | safe-push rebase + bounded retry |
| Real content conflict on rebase | abort, commit stays local, exit 4, alert — never force |
| Agent invents a git identity | canonical identity pinned at system level |
| One identity for all nodes hides *which* node acted | mandatory `origin-node:` trailer + review comment naming the node |
| `git commit -m` sweeps a parallel session's staged files | `commit --only -- <paths>` + commit file-list check |
| `--autostash` loses the other session's staging selection | own stash entry with index; `apply --index`; leftover stash → exit 6 |
| Two local sessions change one clone simultaneously | kernel transaction lock held for the whole transaction |
| Killed writer's lock blocks or frees wrongly | no lock file to clean: inherited `flock`, kernel release |
| Hook "gate" exists in one clone only | versioned hooks, symlinked by installer, `--check` scheduled |
| `git pull` races a parallel fetch in the same clone | explicit refspec into the tracking ref |
| "✓ pushed" printed, commit not on remote | endpoint re-fetch + ancestor check |
| Unpushed commits rot on one node for weeks | hygiene pushes the clean-ahead-not-behind case; alerts the rest |
| Hygiene skips a repo forever | skips are counted; alert after 3 in a row; failed fetch alerts |
| Runtime clone checked out on a branch → deployed untested | runtime clones stay on `main`; build in worktrees |
| Deployed copy drifts from the repo | deploy manifest + scheduled `sha256` comparison |
| Someone reaches for `--force` to "fix" a race | no force in any automated path; human-only, rare |

## Minimal setup steps

1. One shared repo on a remote. Decide now that nodes never sync directly. Data that
   must stay in-house gets an in-network bare origin — same topology.
2. Pin the **canonical git identity** globally on every node; make the `origin-node:`
   trailer part of every automated commit.
3. Install the lock library and the helpers from [`scripts/`](../scripts/); run
   [`scripts/hooks/install.sh`](../scripts/hooks/install.sh) in every clone and put
   `install.sh --check` on a schedule.
4. Give every agent routine the reflex: **fetch-before-edit, `commit --only`, push
   through the helper, immediately.**
5. Add `log.md merge=union` to `.gitattributes` (two machines append at the same place;
   see [docs/02](02-llm-wiki.md)).
6. Schedule the **hygiene watcher** hourly per node; stagger minutes between nodes.
7. Keep runtime clones on `main`; build in worktrees; hash-compare deployed copies.
8. Run [`tests/harness.sh`](../tests/harness.sh) before you trust any of it on your
   machines — and after every change to a script.

## What v1 of this chapter got wrong

Written down so the pattern is not re-learned: the **lock file** (stale-after-5-min,
PID check) handed the lock to a second writer while the first one's `git push` was
still running; the **"explicit staging eliminates the sweep"** claim was false because
`git commit` takes the whole index; the hygiene watcher's **"never auto-push"** left
weeks of commits on one disk; and **`pull --rebase --autostash`** both lost staging
selections and raced on `FETCH_HEAD`. Every one of these was found by measuring the
scripts in throwaway repos, not by reading them. The harness exists so you can do the
same before you believe this chapter.
