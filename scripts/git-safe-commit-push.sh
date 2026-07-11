#!/bin/bash
# =============================================================================
# git-safe-commit-push.sh — cross-machine-safe write primitive for shared repos.
#
# Multiple machines (and multiple agent sessions) write to the same repos.
# A naked `git push` loses races; a naked `git pull` can clobber. This wrapper:
#   1. takes the per-repo write lock (`.sync-lock` — same lock all writers and
#      the hygiene watcher respect; stale locks are cleaned after 5 min)
#   2. stages ONLY the paths you name (never sweeps a parallel session's work)
#   3. commits with the canonical identity
#   4. rebases onto origin (autostash) and pushes, with bounded retries
#   5. ABORTS on rebase conflict — same-file collisions escalate to a human,
#      they are never silently merged or overwritten
#
# Usage:   git-safe-commit-push.sh <repo-dir> "<commit message>" <path> [path...]
# Env:     GSCP_DRYRUN=1   show what would happen, change nothing
#          GIT_IDENT       "12345+youruser@users.noreply.github.com" (recommended:
#                          set globally once per node; never let an agent invent one)
# =============================================================================
set -euo pipefail

REPO="${1:?usage: git-safe-commit-push.sh <repo-dir> \"<msg>\" <path...>}"
MSG="${2:?commit message required}"
shift 2
[ $# -ge 1 ] || { echo "at least one path required" >&2; exit 2; }

cd "$REPO"

GITID="${GIT_IDENT:-$(git config user.email || true)}"
[ -n "$GITID" ] || { echo "⛔ no git identity: set GIT_IDENT or git config user.email" >&2; exit 2; }
BR="$(git symbolic-ref --short HEAD)"   # works on main OR master; fails loudly on detached HEAD
MAXTRIES=5

# one writer per repo per machine at a time — the SAME lock file every writer
# (this script, log-append.sh) takes and the hygiene watcher checks.
LOCK=".sync-lock"
take_lock() { ( set -o noclobber; echo "$$|$(date +%s)|$MSG" > "$LOCK" ) 2>/dev/null; }
if ! take_lock; then
  # stale-lock cleanup: holder died (kill -9 / reboot) or is older than 5 min
  LOCK_TS="$(cut -d'|' -f2 "$LOCK" 2>/dev/null || echo 0)"
  LOCK_PID="$(cut -d'|' -f1 "$LOCK" 2>/dev/null || echo 0)"
  if ! kill -0 "$LOCK_PID" 2>/dev/null || [ $(( $(date +%s) - ${LOCK_TS:-0} )) -gt 300 ]; then
    rm -f "$LOCK"
  fi
  if ! take_lock; then
    echo "⛔ lock held ($(cat "$LOCK" 2>/dev/null)) — another writer is mid-commit; retry shortly" >&2
    exit 3
  fi
fi
trap 'rm -f "$LOCK"' EXIT

git add -- "$@"
if git diff --cached --quiet; then
  echo "nothing to commit for: $*"
  exit 0
fi

if [ "${GSCP_DRYRUN:-0}" = "1" ]; then
  echo "[dry-run] would commit:"; git diff --cached --stat
  git reset -q -- "$@"     # unstage ONLY our paths — never a parallel session's
  exit 0
fi

git -c user.email="$GITID" commit -q -m "$MSG"

for i in $(seq 1 "$MAXTRIES"); do
  # rebase-abort-on-conflict: never clobber another machine's same-file edit
  if ! git pull --rebase --autostash --quiet origin "$BR"; then
    git rebase --abort 2>/dev/null || true
    echo "⛔ rebase conflict — same file changed on another machine. Resolve manually." >&2
    exit 4
  fi
  if git push --quiet origin "$BR"; then
    echo "✓ pushed (attempt $i) — HEAD $(git rev-parse --short HEAD)"
    exit 0
  fi
  sleep 2
done

echo "⛔ push failed after $MAXTRIES attempts (origin unreachable?)" >&2
exit 5
