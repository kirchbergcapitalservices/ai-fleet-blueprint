#!/bin/bash
# =============================================================================
# log-append.sh — atomic append to the wiki's append-only log.md.
#
# Why this exists: multiple agent sessions append to log.md concurrently. A
# naked `echo >> log.md` + separate commit loses appends in races (proven the
# hard way). This helper does pull→append→commit→push under the same per-repo
# write lock (`.sync-lock`) all other writers use.
#
# Order matters: we pull BEFORE appending. If the pull hits a conflict we
# abort the rebase and exit WITHOUT touching log.md — so a retry never
# produces a duplicate entry.
#
# Usage: log-append.sh "## YYYY-MM-DD — type — title
# ...entry body..."
# =============================================================================
set -euo pipefail

WIKI="${WIKI_DIR:-$HOME/Developer/wiki}"
ENTRY="${1:?log entry required}"
LOCK="$WIKI/.sync-lock"

cd "$WIKI"
BR="$(git symbolic-ref --short HEAD)"

# same noclobber lock + stale cleanup as git-safe-commit-push.sh
take_lock() { ( set -o noclobber; echo "$$|$(date +%s)|log-append" > "$LOCK" ) 2>/dev/null; }
for i in $(seq 1 30); do
  take_lock && break
  LOCK_TS="$(cut -d'|' -f2 "$LOCK" 2>/dev/null || echo 0)"
  LOCK_PID="$(cut -d'|' -f1 "$LOCK" 2>/dev/null || echo 0)"
  if ! kill -0 "$LOCK_PID" 2>/dev/null || [ $(( $(date +%s) - ${LOCK_TS:-0} )) -gt 300 ]; then
    rm -f "$LOCK"; continue
  fi
  sleep 1
  [ "$i" = 30 ] && { echo "⛔ could not acquire write lock" >&2; exit 3; }
done
trap 'rm -f "$LOCK"' EXIT

# pull FIRST — abort cleanly on conflict, before we touch log.md
if ! git pull --rebase --autostash -q origin "$BR"; then
  git rebase --abort 2>/dev/null || true
  echo "⛔ pull conflict — resolve manually, then retry (log.md untouched)" >&2
  exit 4
fi

printf '\n%s\n' "$ENTRY" >> log.md
git add log.md
FIRST_LINE="$(printf '%s' "$ENTRY" | head -1)"
git commit -q -m "log: $FIRST_LINE"

for i in 1 2 3; do
  if git pull --rebase --autostash -q origin "$BR" 2>/dev/null; then
    if git push -q origin "$BR" 2>/dev/null; then
      echo "✓ pushed: $(git rev-parse --short HEAD)"
      exit 0
    fi
  else
    git rebase --abort 2>/dev/null || true
    echo "⛔ conflict during push-retry — entry is committed locally; reconcile manually" >&2
    exit 4
  fi
  sleep 2
done
echo "⛔ push failed (entry is committed locally — will go out with the next successful push)" >&2
exit 1
