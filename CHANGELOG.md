# Changelog

## v2.0 — October 2026

Everything in v1.1 was re-audited chapter by chapter against the live setup. Most of it held.
Three things changed because we learned better, and a lot was missing because it did not exist
yet in July.

### How this release was made

A worker node re-audited every one of the 21 files of v1.1 against the live setup and
its incident log, line by line — 133 audited lines, each a statement that teaches a pattern or a
place where a lesson should have stood. Result: 37 still valid, 35 outdated (we do it differently now, for a measured reason), 40 missing
(lessons that did not exist in July), 20 **wrong** (false or self-contradictory already
on the day v1.1 shipped), 1 undecidable. Every v1.1 script was then run in throwaway
repos to *measure* the suspected defects before anything was rewritten. The two worst
findings are the first two items below.

### Withdrawn (we were wrong, and we measured it)

- **The write helpers published other sessions' work.** `git-safe-commit-push.sh` and
  `log-append.sh` ran `git add <paths>; git commit -m …` — and `git commit` takes the whole
  index, so a parallel session's staged files were committed and pushed under your message,
  exit 0. `pull --rebase --autostash` additionally lost the other session's staging selection.
  `docs/04` claimed explicit staging had "eliminated an entire class". Replaced by
  `commit --only -- <paths>` with a file-list check, an own stash entry with `--index`, and a
  distinct exit code when a stash is left behind (harness T9, T10).
- **Two machines appending to the log collided every time.** Without `log.md merge=union`
  every concurrent append ended in a rebase conflict with one entry stranded locally — the
  normal case, not an edge case. `.gitattributes` added; the helper warns if it is missing.

- **The PID-file lock with a stale-after-5-minutes rule** (`.sync-lock` via `noclobber`) taught
  in `docs/04` and used by `log-append.sh` / `git-safe-commit-push.sh`. An independent audit of the
  live setup found two critical holes: a killed script freed the lock while its `git` child was
  still writing, and the age rule evicted a live-but-slow holder. Replaced by a **kernel lock**
  held on an open file description for the whole transaction, inherited by git children and
  released by the kernel when the last holder exits — no stale state, no PID check, no age rule.
  The marker file remains as information only. New: `scripts/lib/repo-lock.sh`, rewritten
  `log-append.sh`, `git-safe-commit-push.sh`, `git-hygiene-sync.sh`, versioned hooks with an installer.

- **Security claims that promised more than the mechanics held.** "Blast radius = one repo"
  is false with an account-wide token on the node; "the brief IS the permission boundary"
  confused scope with rights; a secret-scanning *pre-commit* hook is not a barrier because
  `.git/hooks` is not cloned — server-side push protection is. Added: a privileged job must
  never execute a file the agent user can write; deny-lists are a probed safety net, not a wall.
- **Watchers that knew only green and red.** "Heartbeat on success", `fetch || true`,
  "unreachable = FAIL", and a backup script that wrote "ok" after an unchecked `rsync` and
  with zero directories mirrored. Replaced by verdict records with expiry at every exit and
  a third state, *unchecked*, that is never green (`docs/06`, both scripts rewritten).
- **The department-head delegation model.** "Workers do not publish, the hub curates" had
  already been replaced by action gates with human sign-off on every node — one day before
  v1.1 shipped. Also added the headless iron rule (background work dies with the turn),
  prose-vs-code write paths, and "done = pushed + hash, verified at the receiving end".
- **Two writers "converging" on one memory subtree.** Contradicted the one-writer rule in the
  same repo. Now: one writer per subtree; the backstop reads and alarms.

### New chapters

- `docs/00-start-here.md` — for workshop participants and students: what you saw → where it is written down.
- `docs/09-second-engine-broker.md` + `scripts/broker-pocket.py` — running a second model family
  under three guarantees (reconstructible hash-chained log, data-class gate before start, no
  leftover processes or inherited secrets), fan-out as provider-diverse verification, and eleven
  measured security lessons from building it.
- `docs/10-code-gates.md` — merge is deploy: path-scoped PR gate, a different node merges, a second
  model reviews the exact commit, review requests travel as git objects, a report-only watcher.

### Extended chapters

- `docs/02` — monthly log rotation, nightly lint, branch policy for the log, and two rules about
  negative statements (date them, give them a positive control).
- `docs/03` — the 80 % context checkpoint and the handoff note; threads vs. jobs.
- `docs/05` — the fleet inbox.
- `docs/08` — the premise audit (refute your own findings before consolidating) and the
  three-engines / three-roles research pattern with measured error rates.
- README — ten new hard-won rules.

### Found by the second-model reviews of the release candidate (fixed before publishing)

- the backup job wrote `ok` on the run *after* a failed push without pushing the local commit;
  `log-append.sh` duplicated an entry when re-run after a failed fetch; a failed endpoint re-check
  after a push returned 0 (now a distinct exit 8 = *unchecked*); a plain `stash apply` fallback
  could drop another session's staging selection and report success; the backup mirrored outside
  the clone's transaction lock; the hygiene watcher did less than `docs/04` promised (push of the
  clean-ahead case, clone discovery, pull opt-out — now implemented and tested); the inbox chapter
  overstated what a `git mv` claim guarantees. A second round found: header-only de-duplication in
  `log-append.sh` could drop a different entry with the same header (now whole-entry identity); a
  missing tracking ref read as "nothing pending" (now a fetch first, else exit 8); the health probe
  accepted `{"status":"fail"}` and a record without expiry as green; a dry-run returned 0 after a
  failed `git add`. A third round found: the whole-entry identity was a substring test (a shorter
  entry that is a prefix of a longer one read as "present"; newline framing still failed for
  multi-line entries — identity is now a per-clone digest recorded before the commit plus the text); the off-branch redirect of
  `log-append.sh` skipped the endpoint re-check; `docs/02` described an index gate as if the
  generic helper shipped here implemented it.

### Tests

- `tests/aux-scripts.sh` — 28 checks for the backup and health scripts: both profiles mirrored, zero-dirs → fail, foreign staging stays out, a commit left local by a failed push is pushed by the next run, three states, expiry, an unhealthy `/healthz` body is not ok, a record without expiry is unchecked, notify on state change, an explicitly configured but missing profile dir → fail. The backup mirror uses `rsync --checksum`: the default quick check missed a same-size file rewritten within the same second (found because a test was flaky). The transaction lock now lives in the repository's *common* git dir, so linked worktrees — which share the stash list — share the lock; a stash entry is re-verified by SHA before it is dropped.
- `tests/harness.sh` — throwaway repos, no network, 64 checks: lock contention, dead-holder release
  (the positive control against the old stale-lock pattern), conflict abort without clobber,
  parallel log appends, hook pass-through and block, hygiene skip while locked, hygiene push of the
  clean-ahead case, diverged → alert, opt-out marker, clone discovery, dry-run index isolation, log-append identity on re-run, exit 8 when the endpoint re-check is impossible (also for the off-branch log redirect), prefix-collision identity, nothing-pending with an unreachable remote, dry-run with a bad pathspec, multi-line prefix identity, failed-fetch retry of the same log entry, unwritable digest → spool, unappendable log → spool with no digest left behind.

## v1.1 — July 2026

First public release: 5-layer model, LLM-maintained wiki, memory layers, multi-writer git,
worker delegation, watchdogs, security, quality gates; five scripts, three templates.
