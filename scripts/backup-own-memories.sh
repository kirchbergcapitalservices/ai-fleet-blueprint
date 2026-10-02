#!/bin/bash
# =============================================================================
# backup-own-memories.sh — a WORKER node self-pushes its own agent memories,
# so backups keep running even when the hub laptop is OFFLINE (travel-proof).
#
# The agent CLI keeps a separate memory dir per project under EACH PROFILE
# directory it runs with (interactive profile, headless worker profile …). On a
# worker those memories exist on exactly ONE machine — a rebuild would erase
# what the agent learned. This job mirrors every profile's memories into this
# node's subtree of the shared node-memory repo.
#
# ONE WRITER per subtree: only this node writes <node>/… in node-memory. The hub
# pulls the repo (second copy) and READS this job's record — it never mirrors
# into the same subtree (v1 had two writers "converging" on one path; that is
# the setup in which a second mirror with --delete once erased data).
#
# Usage:    backup-own-memories.sh <node-name>        # e.g. worker-a
# Schedule: cron, e.g.  47 */6 * * *
# Record:   $HOME/.records/backup-own-memories-<node>.record — written at EVERY
#           end (ok|fail, rc, ts, max_age_s, last line); persistent path, not /tmp.
# Env:      MEMORY_SRCS   space-separated profile dirs holding <dir>/*/memory
#                         (default: $HOME/.claude/projects $HOME/.claude-worker/projects)
#           NODE_MEMORY   clone path (default: first of ~/node-memory, ~/Developer/node-memory)
#           NOTIFY_HELPER notification helper (default $HOME/bin/notify)
#           RECORD_MAX_AGE_S expiry written into the record (default 46800 = 13 h ≈ 2× cadence)
#
# LESSONS baked in:
#  - never hardcode a list of source paths — glob the parent (a hardcoded
#    2-path list once silently missed ~22 projects)
#  - a missing SOURCE dir is a FAILURE, not an empty success; so is ZERO mirrored
#    directories from an existing source (wrong user? wrong profile?)
#  - every step's exit code is checked; "ok" is written only when the commit is
#    on the remote (v1 ignored rsync's and git commit's rc — a failed commit
#    followed by an empty push produced a green heartbeat)
#  - the record is written by an EXIT trap before any exit path — a job that dies
#    at a gate writes a FAIL record, not nothing
#  - commit + push through git-safe-commit-push.sh: transaction lock, commit --only
#    this subtree, fetch by refspec, rebase, bounded retry, endpoint check
# =============================================================================
set -o pipefail

NODE="${1:?usage: backup-own-memories.sh <node-name>}"
NOTIFY="${NOTIFY_HELPER:-$HOME/bin/notify}"
SRCS="${MEMORY_SRCS:-$HOME/.claude/projects $HOME/.claude-worker/projects}"
RECDIR="$HOME/.records"; mkdir -p "$RECDIR"
RECORD="$RECDIR/backup-own-memories-$NODE.record"
MAX_AGE="${RECORD_MAX_AGE_S:-46800}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SAFE_PUSH="${SAFE_PUSH:-$HERE/git-safe-commit-push.sh}"
LAST=""

write_record() {  # verdict rc note — atomic replace
  printf 'verdict=%s\nrc=%s\nts=%s\nmax_age_s=%s\nlast=%s\n' \
    "$1" "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MAX_AGE" "$3" > "$RECORD.tmp" \
    && mv -f "$RECORD.tmp" "$RECORD"
}
VERDICT_OVERRIDE=""
on_exit() {
  local rc=$?
  if [ "$rc" -eq 0 ]; then write_record "${VERDICT_OVERRIDE:-ok}" 0 "$LAST"; else write_record fail "$rc" "$LAST"; fi
  command -v repo_lock_release >/dev/null 2>&1 && repo_lock_release
}
trap on_exit EXIT

fail() {  # notify + exit; the EXIT trap writes the FAIL record
  LAST="$1"
  [ -x "$NOTIFY" ] && "$NOTIFY" -t "Memory backup FAILED ($NODE)" "$1"
  echo "FAIL: $1" >&2
  exit "${2:-1}"
}

# Sources: with MEMORY_SRCS set explicitly, EVERY listed dir must exist — a configured profile that
# has vanished is a finding, not something to skip (a run that mirrors the surviving profile and
# records "ok" hides exactly the loss this job exists to prevent). With the default list, at least
# one of the two standard profile dirs must exist; the record names which ones were mirrored.
missing=""; found_src=0
for S in $SRCS; do if [ -d "$S" ]; then found_src=1; else missing="$missing $S"; fi; done
if [ -n "${MEMORY_SRCS:-}" ] && [ -n "$missing" ]; then fail "configured memory source dir(s) missing:$missing" 3; fi
[ "$found_src" -eq 1 ] || fail "no memory source dir exists among: $SRCS (wrong user or profile?)" 3

# locate the node-memory clone
NM="${NODE_MEMORY:-}"
if [ -z "$NM" ]; then
  for c in "$HOME/node-memory" "$HOME/Developer/node-memory"; do
    [ -d "$c" ] && git -C "$c" rev-parse --git-dir >/dev/null 2>&1 && { NM="$c"; break; }
  done
fi
[ -n "$NM" ] || fail "node-memory clone missing" 3
[ -x "$SAFE_PUSH" ] || fail "git-safe-commit-push.sh not found/executable at $SAFE_PUSH" 3

# Hold the clone's transaction lock for the WHOLE job — mirroring into the working tree and
# `git add` must not interleave with another helper's stash/rebase in the same clone. The
# safe-push child inherits the lock and does not wait for us.
# shellcheck source=lib/repo-lock.sh
REPO_LOCK_NO_TRAP=1   # this script owns the EXIT trap (record first, then release)
. "$HERE/lib/repo-lock.sh" || fail "lock library missing" 3
repo_lock_acquire "$NM" "backup-own-memories $NODE" || fail "clone is busy (another writer holds the lock) — try again later" 3

# mirror EVERY profile's EVERY project memory dir (glob, not a hardcoded list)
mirrored=0
for S in $SRCS; do
  [ -d "$S" ] || continue
  PROFILE="$(basename "$(dirname "$S")")"          # e.g. .claude or .claude-worker
  PROFILE="${PROFILE#.}"
  for d in "$S"/*/memory; do
    [ -d "$d" ] || continue
    KEY="$(basename "$(dirname "$d")")"
    [ -z "$(ls -A "$d" 2>/dev/null | grep -vE '^\.' || true)" ] && continue
    dst="$NM/$NODE/memory/$PROFILE/$KEY"
    mkdir -p "$dst" || fail "mkdir failed: $dst" 1
    # --checksum: rsync's default quick check (size + mtime) misses a file rewritten with the same
    # size within the same second as the previous mirror — found by a flaky test, real for memory
    # files an agent rewrites repeatedly. Memory dirs are small; the checksum cost is nothing.
    if ! rsync -a --checksum --delete --exclude='.DS_Store' "$d/" "$dst/"; then
      fail "rsync failed for $d" 1
    fi
    mirrored=$((mirrored + 1))
  done
  SRCS_USED="${SRCS_USED:-} $PROFILE"
done
[ "$mirrored" -gt 0 ] || fail "zero memory directories mirrored from existing sources ($SRCS) — wrong profile dir?" 3

# commit + push ONLY this node's subtree. ALWAYS call the helper, even with nothing new staged:
# a commit left local by a failed push is pushed by this run — "nothing changed" was never
# "done" while a local commit sat unpushed (v2.0-rc wrote "ok" in exactly that case).
git -C "$NM" add -A -- "$NODE/memory" || fail "git add failed" 1
"$SAFE_PUSH" "$NM" "auto: $NODE self-backup memories ($mirrored dirs)" "$NODE/memory"
rc=$?
case "$rc" in
  0) LAST="pushed/verified ($mirrored dirs from:${SRCS_USED:-})"; exit 0 ;;
  8) LAST="pushed, endpoint unchecked ($mirrored dirs)"; VERDICT_OVERRIDE=unchecked; exit 0 ;;
  4) fail "rebase conflict — commit is local, nothing overwritten; a human reconciles" 4 ;;
  5) fail "not pushed — commit is local; next run retries" 5 ;;
  6) fail "another session's work was left in git stash list (pushed or not — see helper output) — look before the next write" 6 ;;
  *) fail "git-safe-commit-push.sh exit $rc" "$rc" ;;
esac
