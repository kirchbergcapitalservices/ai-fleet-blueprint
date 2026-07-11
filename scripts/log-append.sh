#!/bin/bash
# =============================================================================
# log-append.sh — atomic append to the wiki's append-only log.md.
#
# Why this exists: multiple agent sessions append to log.md concurrently. A
# naked `echo >> log.md` + separate commit loses appends in races (proven the
# hard way). This helper does the whole append→commit→push under a lock.
#
# Usage: log-append.sh "## YYYY-MM-DD — type — title
# ...entry body..."
# =============================================================================
set -euo pipefail

WIKI="${WIKI_DIR:-$HOME/Developer/wiki}"
ENTRY="${1:?log entry required}"
LOCKDIR="$WIKI/.log-append.lock"

cd "$WIKI"

# POSIX mkdir lock (atomic), with stale cleanup
for i in $(seq 1 30); do
  if mkdir "$LOCKDIR" 2>/dev/null; then break; fi
  # stale if older than 5 min
  if [ -d "$LOCKDIR" ] && [ $(( $(date +%s) - $(stat -f %m "$LOCKDIR") )) -gt 300 ]; then
    rmdir "$LOCKDIR" 2>/dev/null || true
  fi
  sleep 1
  [ "$i" = 30 ] && { echo "⛔ could not acquire log lock" >&2; exit 3; }
done
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

git pull --rebase --autostash -q origin main 2>/dev/null || true

printf '\n%s\n' "$ENTRY" >> log.md
git add log.md
FIRST_LINE="$(printf '%s' "$ENTRY" | head -1)"
git commit -q -m "log: $FIRST_LINE"

for i in 1 2 3; do
  if git pull --rebase --autostash -q origin main 2>/dev/null && git push -q origin main 2>/dev/null; then
    echo "✓ pushed: $(git rev-parse --short HEAD)"
    exit 0
  fi
  sleep 2
done
echo "⛔ push failed (entry is committed locally)" >&2
exit 1
