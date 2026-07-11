# 04 — Multi-Writer Git as the Fleet Nervous System

Three machines, several long-running agents, one shared body of knowledge. The
hard part is not the AI — it is keeping three writers from stepping on each
other. Our answer is boring on purpose: **git is the only nervous system, and
GitHub is the only hub.** Nodes never talk to each other directly. They talk to
a remote, and the remote fans state back out.

This chapter is the coordination layer everything else in the fleet stands on.

## The one rule: hub-and-spoke, never node-to-node

```
        ┌───────────┐
        │  GitHub   │   ← the ONLY meeting point
        └─────┬─────┘
   push/pull  │  push/pull
   ┌──────────┼──────────┐
   │          │          │
┌──▼──┐    ┌──▼───┐   ┌──▼───┐
│ hub │    │work-a│   │work-b│
└─────┘    └──────┘   └──────┘
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
| `rsync` between nodes            | shared repo, `git pull --rebase`           |
| "just edit it live on both"      | one writer at a time, push immediately     |
| shared network drive as truth    | git history is truth; disk is a cache      |

## Canonical git identity everywhere

Every node — and every agent on every node — commits as the **same, fixed
identity**. This is set once at the system level, not left to the agent:

```bash
git config --global user.name  "fleet-bot"
git config --global user.email "fleet-bot@users.noreply.github.com"
```

Why this matters more than it looks: an agent left to its own devices will
*invent* a git identity from the environment, and you end up with commits
authored by `root`, by a random hostname, or by a half-hallucinated name. That
pollutes `git blame`, breaks signed-commit rules, and makes it impossible to
tell fleet-automated commits from human ones. **Never let an agent choose its
own identity** — pin it, and (optionally) tag machine-origin in the commit body
instead:

```
knowledge: add carrier-stability note

origin-node: worker-b
```

## Pull before edit, push immediately

The whole discipline collapses to two habits, drilled into every agent's
routine and enforced by wrappers:

1. **Pull before you edit.** Never start from a stale tree.
2. **Push immediately after you commit.** A commit sitting unpushed for an hour
   is a landmine for the next writer.

| Step        | Command                              | Why                                  |
| ----------- | ------------------------------------ | ------------------------------------ |
| before edit | `git pull --rebase --autostash`      | start from remote truth              |
| after edit  | `git add <specific files>`           | stage only what you touched          |
| commit      | `git commit -m "scope: change"`      | small, scoped, descriptive           |
| publish     | safe-push (below)                    | get it off the local machine now     |

The longer a change lives only on one node, the higher the chance a parallel
writer diverges and you inherit a conflict you have to hand-resolve.

## Safe-push: rebase, bounded retry, abort on conflict

A naive `git push` fails the moment someone else pushed first. A naive
`push --force` "fixes" that by destroying their work. Both are wrong. We wrap
push in a script with one guiding principle: **never clobber, never loop
forever.**

```bash
safe_push() {
  local tries=0 max=5
  while (( tries < max )); do
    if git pull --rebase --autostash; then
      if git push; then return 0; fi          # success
    else
      git rebase --abort 2>/dev/null           # conflict → back off, do NOT force
      echo "conflict on rebase — leaving tree clean for a human"; return 2
    fi
    (( tries++ )); sleep $(( tries * 2 ))       # bounded backoff on push race
  done
  echo "push still racing after $max tries — alerting"; return 3
}
```

The rules encoded here:

- **`--rebase --autostash`** replays our commit on top of the latest remote, so
  history stays linear and our local edits are auto-stashed out of the way.
- **Bounded retry** (5 tries, growing backoff) handles the normal case of two
  nodes pushing within the same second. It gives up instead of spinning.
- **Abort on conflict = never clobber.** If the rebase hits a real content
  conflict, we `--abort` and hand a clean tree to a human. We would rather stall
  a push than silently overwrite another writer's work. There is no `--force`
  anywhere in the fleet's automated paths.

## Same-machine locks: two agents, one repo

The remote handles cross-node races. But two agent sessions on the *same*
machine can corrupt an in-progress commit or stage each other's half-written
files. For that we use a local lock plus a pre-commit guard.

```bash
LOCK="$repo/.git/fleet.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "another local session holds the repo lock — waiting/skip"; exit 1
fi
# … do the pull → edit → commit → push under the lock …
```

| Mechanism            | Guards against                         | Scope        |
| -------------------- | -------------------------------------- | ------------ |
| `flock` lockfile     | two local sessions committing at once  | one machine  |
| pre-commit hook      | committing when a sibling holds lock   | one machine  |
| safe-push rebase     | two nodes pushing to the remote        | whole fleet  |

The lockfile is same-machine only — `flock` does not reach across nodes, and it
does not need to, because the remote already serializes cross-node writes.

## File-scoped staging: the parallel-session sweep

The nastiest bug we hit early: an agent runs `git add -A`, and because a
*parallel* session had unrelated half-finished edits in the same working tree,
those got swept into the wrong commit. Now every automated commit stages an
explicit file list — never `-A`, never `.`:

```bash
git add -- "wiki/notes/kestrel.md" "log.md"   # exactly the files this task owns
```

A thin wrapper (`commit --files a.md b.md`) refuses to run if you pass no file
list. This one guard eliminated an entire class of "why is this unrelated file
in my commit" incidents.

## Hourly git-hygiene watcher

A scheduled job on each node checks repo health every hour and — critically —
**never auto-pushes.** It observes and, at most, fast-forwards a clean tree.

| Repo state             | Watcher action                                   |
| ---------------------- | ------------------------------------------------ |
| clean + behind remote  | `git pull --ff-only` (safe fast-forward)         |
| clean + up to date     | nothing                                          |
| dirty (uncommitted)    | **alert only** — a human decides                 |
| committed but unpushed | **alert only** — never auto-push unreviewed work |

The asymmetry is deliberate. *Pulling* clean updates into a clean tree is safe
and keeps nodes fresh. *Pushing* is a publishing act — it can expose half-done
or wrong content — so the watcher refuses to do it unattended. Auto-pull, yes;
auto-publish, never.

## Failure modes & guards

| Failure mode                                   | Guard                                             |
| ---------------------------------------------- | ------------------------------------------------- |
| Two nodes push at once → one rejected          | safe-push rebase + bounded retry                  |
| Real content conflict on rebase                | abort, leave clean tree, alert — never force      |
| Agent invents a git identity                   | canonical identity pinned at system level         |
| `git add -A` sweeps a parallel session's files | file-scoped staging, `--files` guard              |
| Two local sessions commit simultaneously       | `flock` lockfile + pre-commit hook                |
| Unpushed commit rots on one node               | hourly watcher alerts on unpushed                 |
| Node drifts silently behind                    | hourly watcher fast-forwards clean trees          |
| Someone reaches for `--force` to "fix" a race  | no force in any automated path; human-only, rare  |

## Minimal setup steps

1. Create one shared repo on GitHub. This is the **only** hub — decide now that
   nodes never sync directly.
2. On every node, pin the **canonical git identity** globally.
3. Give every agent routine the reflex: **pull-before-edit, push-immediately.**
4. Drop in a **safe-push** wrapper: `pull --rebase --autostash` → push → bounded
   retry → **abort on conflict, never force.**
5. Add a **`flock` lockfile + pre-commit hook** so two local sessions serialize.
6. Enforce **file-scoped staging** — ban `git add -A` in automation; require an
   explicit file list.
7. Schedule an **hourly hygiene watcher**: ff-pull clean trees, alert on
   dirty/unpushed, **never auto-push.**

Get these seven right and the fleet's shared brain stays coherent no matter how
many agents write to it. Everything downstream — the wiki, the watchdogs, the
quality gates — assumes this layer holds.
