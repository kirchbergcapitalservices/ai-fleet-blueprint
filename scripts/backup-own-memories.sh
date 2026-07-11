#!/bin/bash
# =============================================================================
# backup-own-memories.sh — a WORKER node self-pushes its own agent memories,
# so backups keep running even when the hub laptop is OFFLINE (travel-proof).
#
# Claude Code writes a separate memory dir per project it works in. On a worker
# those memories exist on exactly ONE machine — a rebuild would erase what the
# agent learned. This job mirrors them into the shared node-memory repo.
#
# Complements (does not replace) a hub-side pull-backstop: both write the same
# subtree with identical rsync content → they converge; whoever runs second
# finds no diff. Two independent copy paths, one truth.
#
# Usage:    backup-own-memories.sh <node-name>        # e.g. worker-a
# Schedule: cron, e.g.  47 */6 * * *  (heartbeat file proves it ran — watch it!)
#
# LESSON baked in: never hardcode a list of source paths in a backup script —
# glob the parent. A hardcoded 2-path list once silently missed ~22 projects.
# =============================================================================
set -o pipefail

NODE="${1:?usage: backup-own-memories.sh <node-name>}"
NOTIFY="${NOTIFY_HELPER:-$HOME/bin/notify}"
SRC="$HOME/.claude-worker/projects"        # worker profile's project memories
HB="/tmp/backup-own-memories-$NODE.done"   # heartbeat (note: /tmp dies on reboot)
TS="$(date '+%Y-%m-%d %H:%M:%S')"

# locate the node-memory clone
NM=""
for c in "$HOME/node-memory" "$HOME/Developer/node-memory"; do
  [ -d "$c/.git" ] && { NM="$c"; break; }
done
if [ -z "$NM" ]; then
  echo "$TS FAIL: node-memory clone missing" > "$HB"
  [ -x "$NOTIFY" ] && "$NOTIFY" -t "Memory backup FAILED ($NODE)" "node-memory clone missing"
  exit 3
fi

cd "$NM" || exit 3
git pull --rebase --autostash -q origin main 2>/dev/null || true

# mirror EVERY project's memory dir (glob, not a hardcoded list)
for d in "$SRC"/*/memory; do
  [ -d "$d" ] || continue
  KEY="$(basename "$(dirname "$d")")"
  [ -z "$(ls -A "$d" 2>/dev/null | grep -vE '^\.' || true)" ] && continue
  dst="$NM/$NODE/claude-worker-memory/$KEY"
  mkdir -p "$dst"
  rsync -a --delete --exclude='.DS_Store' "$d/" "$dst/" 2>/dev/null
done

# commit + push (disjoint path = only this node's subtree; rebase-safe retry)
git add "$NODE/claude-worker-memory" 2>/dev/null
FAIL=""
if ! git diff --cached --quiet; then
  git commit -q -m "auto: $NODE self-backup worker memories $TS"
  pushed=""
  for i in 1 2 3; do
    if git pull --rebase --autostash -q origin main 2>/dev/null && git push -q origin main 2>/dev/null; then
      pushed=1; break
    fi
    sleep 3
  done
  [ -z "$pushed" ] && FAIL="push-failed"
fi

echo "$TS $NODE self-backup ${FAIL:-ok}" > "$HB"
if [ -n "$FAIL" ]; then
  [ -x "$NOTIFY" ] && "$NOTIFY" -t "Memory backup FAILED ($NODE)" "$NODE self-backup: $FAIL"
  exit 1
fi
exit 0
