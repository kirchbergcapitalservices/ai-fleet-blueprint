#!/bin/bash
# =============================================================================
# git-safe-commit-push.sh — cross-machine-safe write primitive for shared repos.
#
# Multiple machines (and multiple agent sessions) write to the same repos.
# A naked `git push` loses races; a naked `git pull` can clobber. This wrapper:
#   1. stages ONLY the paths you name (never sweeps a parallel session's work)
#   2. commits with the canonical identity
#   3. rebases onto origin (autostash) and pushes, with bounded retries
#   4. ABORTS on rebase conflict — same-file collisions escalate to a human,
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

GITID="${GIT_IDENT:-$(git -C "$REPO" config user.email)}"
MAXTRIES=5

cd "$REPO"

# one writer per repo per machine at a time (POSIX noclobber lock)
LOCK=".safe-push.lock"
if ! ( set -o noclobber; echo "$$|$(date +%s)|$MSG" > "$LOCK" ) 2>/dev/null; then
  HOLDER="$(cat "$LOCK" 2>/dev/null || true)"
  echo "⛔ lock held ($HOLDER) — another writer is mid-commit; retry in a few seconds" >&2
  exit 3
fi
trap 'rm -f "$LOCK"' EXIT

git add -- "$@"
if git diff --cached --quiet; then
  echo "nothing to commit for: $*"
  exit 0
fi

if [ "${GSCP_DRYRUN:-0}" = "1" ]; then
  echo "[dry-run] would commit:"; git diff --cached --stat
  git reset -q
  exit 0
fi

git -c user.email="$GITID" commit -q -m "$MSG"

for i in $(seq 1 "$MAXTRIES"); do
  # rebase-abort-on-conflict: never clobber another machine's same-file edit
  if ! git pull --rebase --autostash --quiet origin main; then
    git rebase --abort 2>/dev/null || true
    echo "⛔ rebase conflict — same file changed on another machine. Resolve manually." >&2
    exit 4
  fi
  if git push --quiet origin main; then
    echo "✓ pushed (attempt $i) — HEAD $(git rev-parse --short HEAD)"
    exit 0
  fi
  sleep 2
done

echo "⛔ push failed after $MAXTRIES attempts (origin unreachable?)" >&2
exit 5
