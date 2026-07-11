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
# Schedule: cron, e.g.  47 */6 * * *
# Heartbeat: $HOME/.heartbeats/backup-own-memories-<node>.done — persistent
#            path, NOT /tmp (which is wiped on reboot → false-stale alarms).
#
# LESSONS baked in:
#  - never hardcode a list of source paths — glob the parent (a hardcoded
#    2-path list once silently missed ~22 projects)
#  - a missing SOURCE dir is a FAILURE, not an empty success: wrong user/path
#    would otherwise back up nothing while the heartbeat says "ok" forever
# =============================================================================
set -o pipefail

NODE="${1:?usage: backup-own-memories.sh <node-name>}"
NOTIFY="${NOTIFY_HELPER:-$HOME/bin/notify}"
SRC="${MEMORY_SRC:-$HOME/.claude-worker/projects}"   # worker profile's project memories
HBDIR="$HOME/.heartbeats"; mkdir -p "$HBDIR"
HB="$HBDIR/backup-own-memories-$NODE.done"
TS="$(date '+%Y-%m-%d %H:%M:%S')"

fail() {  # heartbeat says FAIL (never a silent green), notify, exit
  echo "$TS FAIL: $1" > "$HB"
  [ -x "$NOTIFY" ] && "$NOTIFY" -t "Memory backup FAILED ($NODE)" "$1"
  echo "FAIL: $1" >&2
  exit "${2:-1}"
}

# a missing source is a config error (wrong user? wrong profile dir?) — FAIL LOUDLY
[ -d "$SRC" ] || fail "memory source dir missing: $SRC (wrong user or profile?)" 3

# locate the node-memory clone
NM=""
for c in "$HOME/node-memory" "$HOME/Developer/node-memory"; do
  [ -d "$c/.git" ] && { NM="$c"; break; }
done
[ -n "$NM" ] || fail "node-memory clone missing" 3

cd "$NM" || fail "cannot cd into $NM" 3
BR="$(git symbolic-ref --short HEAD)"
if ! git pull --rebase --autostash -q origin "$BR" 2>/dev/null; then
  git rebase --abort 2>/dev/null || true   # never leave the repo mid-rebase
fi

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
if ! git diff --cached --quiet; then
  git commit -q -m "auto: $NODE self-backup worker memories $TS"
  pushed=""
  for i in 1 2 3; do
    if git pull --rebase --autostash -q origin "$BR" 2>/dev/null; then
      git push -q origin "$BR" 2>/dev/null && { pushed=1; break; }
    else
      git rebase --abort 2>/dev/null || true
    fi
    sleep 3
  done
  [ -z "$pushed" ] && fail "push-failed (commit is local; next run retries)" 1
fi

echo "$TS $NODE self-backup ok" > "$HB"
exit 0
