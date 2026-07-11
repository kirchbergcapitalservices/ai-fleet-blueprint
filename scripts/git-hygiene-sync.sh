#!/bin/bash
# =============================================================================
# git-hygiene-sync.sh — hourly per-node backstop against drift and rot.
#
# For every shared repo this node has a checkout of:
#   clean + behind   → fast-forward pull (safely absorbs the others' work)
#   dirty / unpushed → ALERT a human ("commit/push or reconcile") — NO auto-push
#   non-ff situation → ALERT (someone diverged; a human decides)
#
# Deploy on EVERY node via cron, e.g.:  17 * * * * /bin/bash ~/bin/git-hygiene-sync.sh
# (Stagger the minute per node so pulls don't race pushes.)
#
# Design choices that matter:
#  - NO auto-commit/auto-push: the watcher surfaces problems, humans/agents fix
#    them deliberately. Auto-pushing half-finished work spreads breakage.
#  - Skips a repo while its write-lock exists (don't interfere mid-commit).
#  - Repos it doesn't find are skipped silently → one list works fleet-wide.
# =============================================================================
set -uo pipefail

NOTIFY="${NOTIFY_HELPER:-$HOME/bin/notify}"   # any push-notification helper (Telegram/ntfy/...)
NODE="$(hostname -s)"
REPOS="wiki node-memory memory project-alpha project-beta"   # adapt to your fleet

ALERT=""
for r in $REPOS; do
  d="$HOME/Developer/$r"
  [ -d "$d/.git" ] || continue          # this node doesn't have it → fine
  [ -f "$d/.sync-lock" ] && continue    # a writer is mid-commit → don't interfere
  br="$(git -C "$d" symbolic-ref --short HEAD 2>/dev/null)" || continue
  git -C "$d" rev-parse "@{u}" >/dev/null 2>&1 || continue
  git -C "$d" fetch -q origin 2>/dev/null || continue

  dirty="$(git -C "$d" status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
  ahead="$(git -C "$d" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
  behind="$(git -C "$d" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)"

  if [ "$dirty" != 0 ]; then ALERT="${ALERT} ${r}(uncommitted×${dirty})"; continue; fi
  if [ "${ahead:-0}" != 0 ]; then ALERT="${ALERT} ${r}(unpushed×${ahead})"; continue; fi
  if [ "${behind:-0}" != 0 ]; then
    git -C "$d" pull --ff-only origin "$br" >/dev/null 2>&1 || ALERT="${ALERT} ${r}(non-ff)"
  fi
done

if [ -n "$ALERT" ] && [ -x "$NOTIFY" ]; then
  "$NOTIFY" -t "⚠️ git hygiene ${NODE}" "Left behind → commit/push (or reconcile):${ALERT}"
fi
exit 0
