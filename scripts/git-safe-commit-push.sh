#!/bin/bash
# =============================================================================
# git-safe-commit-push.sh — cross-machine-safe write primitive for shared repos.
#
# Several machines (and several agent sessions per machine) write to the same
# repos. A naked `git push` loses races; a naked `git pull` can clobber. This
# wrapper:
#   1. holds the clone's transaction lock (scripts/lib/repo-lock.sh — kernel flock,
#      inherited by git, never evicted; a dead holder holds nothing)
#   2. commits EXACTLY the paths you name: `git commit --only -- <paths>`. Whatever a
#      parallel session has staged stays staged and stays out of this commit.
#      (v1 ran `git add <paths>; git commit` — and `git commit` takes the WHOLE
#      index, including a parallel session's staged files.)
#   3. checks the result: every path in the new commit lies under a named path
#   4. fetches into the tracking ref (explicit refspec — `git pull` reads the shared
#      .git/FETCH_HEAD, which any parallel `git fetch` in the clone can overwrite)
#   5. sets the parallel session's uncommitted work aside with its OWN stash entry
#      (index included, found again by a unique message — the stash list is shared by
#      all worktrees), rebases, restores with `stash apply --index`. `--autostash`
#      restores without --index (the other session's staging selection is lost) and
#      a failed autostash pop still exits 0.
#   6. pushes with bounded retries; a rebase CONFLICT aborts — nothing is overwritten,
#      the commit stays local, a human resolves it. No --force anywhere.
#   7. verifies at the endpoint: re-fetches and checks HEAD is on the remote branch.
#      (Plain `git push` updates the tracking ref itself, so without the fetch the
#      check could never fail.)
#
# Usage:   git-safe-commit-push.sh <repo-dir> "<commit message>" <path> [path...]
# Env:     GSCP_DRYRUN=1    show what would be committed (on a copy of the index — nothing changes)
#          GIT_IDENT        "12345+you@users.noreply.github.com" (else git config user.email;
#                           never let an agent invent an identity)
#          GSCP_REMOTE      default origin · GSCP_MAXTRIES default 5
#          REPO_LOCK_WAIT_S seconds to wait for the lock (default 90)
#          Re-running after exit 5 pushes the commit that is still local (nothing new to commit
#          is not "done" while local commits sit unpushed).
# Exit:    0 pushed and verified at the endpoint (or nothing to commit and nothing pending)
#          1 commit failed / foreign path in commit
#          2 usage / `git add` failed · 3 lock busy (or not checkable)
#          4 rebase conflict — nothing overwritten, commit is local
#          5 not pushed after GSCP_MAXTRIES (or endpoint check failed) — commit is local
#          6 pushed (or not), BUT another session's changes were left in `git stash list`
#          8 pushed, but the endpoint re-check could not run (fetch failed) — UNCHECKED, do not retry
# bash 3.2-safe (macOS default).
# =============================================================================
set -uo pipefail

REPO="${1:-}"; MSG="${2:-}"
[ -n "$REPO" ] && [ -n "$MSG" ] && [ $# -ge 3 ] || {
  echo "usage: git-safe-commit-push.sh <repo-dir> \"<msg>\" <path> [path...]" >&2; exit 2; }
shift 2
HERE="$(cd "$(dirname "$0")" && pwd)"
# rev-parse instead of [ -d .git ]: in a linked worktree .git is a FILE.
ROOT="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)" || { echo "⛔ $REPO is not a git checkout" >&2; exit 2; }
cd "$ROOT" || exit 2

GITID="${GIT_IDENT:-$(git config user.email || true)}"
[ -n "$GITID" ] || { echo "⛔ no git identity: set GIT_IDENT or git config user.email" >&2; exit 2; }
REMOTE="${GSCP_REMOTE:-origin}"
MAXTRIES="${GSCP_MAXTRIES:-5}"

# shellcheck source=lib/repo-lock.sh
. "$HERE/lib/repo-lock.sh"
repo_lock_acquire "$ROOT" "git-safe-commit-push: $MSG" || exit 3
# Read the branch only NOW: while we waited, the holder before us may have switched it.
BR="$(git symbolic-ref --quiet --short HEAD)" || { echo "⛔ detached HEAD — no branch to push" >&2; exit 2; }
TRACK="refs/remotes/$REMOTE/$BR"

# ---- 1-3: stage + commit ONLY the named paths, then prove it --------------------
if [ "${GSCP_DRYRUN:-0}" = 1 ]; then          # on a COPY of the index: the real staging stays as it is
  TMPIDX="$(mktemp "${TMPDIR:-/tmp}/gscp-index.XXXXXX")" || exit 2
  cp "$(git rev-parse --git-path index)" "$TMPIDX" 2>/dev/null || : > "$TMPIDX"
  echo "[dry-run] would commit:"
  if GIT_INDEX_FILE="$TMPIDX" git add -- "$@" && GIT_INDEX_FILE="$TMPIDX" git diff --cached --stat -- "$@"; then drc=0
  else drc=2; echo "⛔ [dry-run] staging would FAIL for: $*" >&2; fi
  rm -f "$TMPIDX"; exit "$drc"
fi
# `git add` must succeed: a failing pathspec adds nothing, and a commit afterwards would
# carry whatever else happened to be staged. Deleted tracked files are fine (stages the deletion).
if ! out="$(repo_git_idx add -- "$@" 2>&1)"; then echo "⛔ git add failed — nothing committed: $out" >&2; exit 2; fi
if git diff --cached --quiet -- "$@"; then
  # Nothing new — but an earlier run may have committed and then failed to push. Do not
  # report success while local commits sit unpushed: go on and push them.
  # "Nothing pending" needs a FRESH tracking ref: a missing or stale ref must not read as zero.
  git fetch -q "$REMOTE" "+refs/heads/$BR:$TRACK" 2>/dev/null \
    || { echo "⚠ nothing new to commit, but $REMOTE could not be fetched — whether commits are pending is UNCHECKED (exit 8)" >&2; exit 8; }
  pending="$(git rev-list --count "$TRACK..HEAD" 2>/dev/null)" \
    || { echo "⚠ nothing new to commit, but $TRACK does not exist — pending state UNCHECKED (exit 8)" >&2; exit 8; }
  if [ "$pending" = 0 ]; then echo "nothing to commit for: $*"; exit 0; fi
  echo "nothing new to commit — pushing $pending local commit(s) left from an earlier run"
else
  repo_git_idx -c user.email="$GITID" commit -q --only -m "$MSG" -- "$@" || { echo "⛔ commit failed (hook?)" >&2; exit 1; }
  # Proof, not trust: every file in the new commit matches one of the named pathspecs.
  # git itself does the matching, so `.`, globs and directories mean what they meant to `git add`.
  all="$(git diff-tree --no-commit-id --name-only -r HEAD | wc -l)"
  mine="$(git diff-tree --no-commit-id --name-only -r HEAD -- "$@" | wc -l)"
  [ "$all" -eq "$mine" ] || { echo "⛔ commit $(git rev-parse --short HEAD) contains paths you did not name — NOT pushed (git show --stat HEAD)" >&2; exit 1; }
fi

# ---- 4-7: fetch → own stash → rebase → restore → push → endpoint check --------------
NOFH=""; case "$(git fetch -h 2>&1)" in *write-fetch-head*) NOFH="--no-write-fetch-head" ;; esac
fetch_tracking() { git fetch -q $NOFH "$REMOTE" "+refs/heads/$BR:$TRACK"; }

STASH=""
# The stash list is SHARED by every worktree of a repo, so "the newest entry" is not
# necessarily ours. Our entry is identified by a unique message and handled by its SHA.
stash_foreign() {     # set a parallel session's uncommitted (tracked) work aside, index included
  local tag="safe-push $$ $(date +%s) $RANDOM"
  STASH=""
  git diff --quiet && git diff --cached --quiet && return 0
  git stash push -q -m "$tag" >/dev/null 2>&1 || return 1
  STASH="$(git log -g --format='%H %gs' refs/stash 2>/dev/null | awk -v t="$tag" 'index($0, t) { print $1; exit }')"
  [ -n "$STASH" ] || { echo "⛔ stashed, but cannot find our entry ('$tag') in git stash list" >&2; return 1; }
}
stash_drop_ours() {   # drop the entry whose SHA is ours, wherever it sits in the list now
  local n
  n="$(git log -g --format='%H' refs/stash 2>/dev/null | awk -v h="$STASH" '$1 == h { print NR - 1; exit }')"
  [ -n "$n" ] || return 0
  # The stash list is shared by every worktree of the repo. The transaction lock is taken in the
  # COMMON git dir, so no other helper mutates the list meanwhile; this re-check guards against a
  # non-helper `git stash` between lookup and drop — never drop an entry that is not ours.
  [ "$(git rev-parse "stash@{$n}" 2>/dev/null)" = "$STASH" ] || { echo "⚠ stash list changed under us — our entry left in place ($STASH)" >&2; return 1; }
  git stash drop -q "stash@{$n}" >/dev/null 2>&1
}
unstash_foreign() {   # rc 1 = left in the stash (said loudly). Never reset --hard: a file
  local u                # writer may have touched the tree meanwhile; that version must survive.
  [ -n "$STASH" ] || return 0
  if git stash apply --index -q "$STASH" >/dev/null 2>&1; then stash_drop_ours; STASH=""; return 0; fi
  # No fallback to a plain `stash apply`: it would restore the files but silently drop the
  # other session's STAGING selection and report success. Leaving the entry in the stash and
  # saying so (exit 6) is the honest outcome.
  u="$(git diff --name-only --diff-filter=U)"
  [ -z "$u" ] || printf '%s\n' "$u" | while IFS= read -r p; do git checkout -q HEAD -- "$p"; done
  echo "⛔ could not restore the other session's changes — they are in \`git stash list\` ($STASH)" >&2
  return 1
}

LEFT=0
i=0
while [ "$i" -lt "$MAXTRIES" ]; do
  i=$((i + 1))
  if ! fetch_tracking; then echo "↻ fetch failed (try $i/$MAXTRIES)" >&2; sleep $((i * 2)); continue; fi
  stash_foreign || { echo "⛔ could not set uncommitted changes aside — commit is local" >&2; exit 4; }
  if ! out="$(git rebase -q "$TRACK" 2>&1)"; then
    git rebase --abort >/dev/null 2>&1 || true
    unstash_foreign || LEFT=1
    echo "⛔ rebase conflict — the same file changed elsewhere. Nothing overwritten; commit $(git rev-parse --short HEAD) is local. Resolve by hand." >&2
    printf '%s\n' "$out" | tail -3 >&2
    [ "$LEFT" = 1 ] && exit 6
    exit 4
  fi
  unstash_foreign || LEFT=1                  # restore BEFORE the push: keep the stash window short
  if git push -q "$REMOTE" "HEAD:refs/heads/$BR"; then
    if fetch_tracking; then
      git merge-base --is-ancestor HEAD "$TRACK" || { echo "⛔ push said ok, but HEAD is not on $REMOTE/$BR" >&2; exit 5; }
    else
      # The push itself succeeded, so a retry would duplicate the change — but "pushed" is
      # not verified either. Distinct code: 8 = pushed, endpoint UNCHECKED. Callers record it
      # as unchecked, never as ok, and never retry the push.
      echo "⚠ pushed, but the endpoint could NOT be re-checked (fetch failed after the push) — exit 8" >&2
      [ "$LEFT" = 1 ] && exit 6
      exit 8
    fi
    echo "✓ pushed (attempt $i) — HEAD $(git rev-parse --short HEAD)"
    [ "$LEFT" = 1 ] && exit 6
    exit 0
  fi
  [ "$LEFT" = 1 ] && { echo "⛔ push failed AND a stash was left behind — commit is local" >&2; exit 6; }
  echo "↻ push race (try $i/$MAXTRIES)" >&2
  sleep $((i * 2))
done
echo "⛔ not pushed after $MAXTRIES attempts — commit $(git rev-parse --short HEAD) is local" >&2
exit 5
