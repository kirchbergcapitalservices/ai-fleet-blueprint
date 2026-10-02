#!/bin/bash
# =============================================================================
# git-hygiene-sync.sh — hourly per-node backstop against drift and rot.
#
# For every shared repo this node has a checkout of:
#  clean + behind   → fast-forward (safely absorbs the others' work) — unless `.hygiene-no-pull` exists in the repo
#  clean + ahead, not behind → PUSH (the one case that cannot clobber anyone)
#  dirty / diverged → ALERT a human ("commit/push or reconcile")
#   non-ff situation → ALERT (someone diverged; a human decides)
#   lock busy        → skip this run, count it; ALERT after HYGIENE_SKIP_ALERT runs in a row
#   lock not checkable → ALERT ("not checked" is never "clean")
#
# Deploy on EVERY node via cron, e.g.:  17 * * * * /bin/bash ~/bin/git-hygiene-sync.sh
# (Stagger the minute per node so pulls don't race pushes.)
#
# Design choices that matter:
#  - The watcher TAKES the clone's transaction lock (scripts/lib/repo-lock.sh) for the
#    whole fetch/status/fast-forward of a repo, waiting HYGIENE_LOCK_WAIT_S (default 5 s).
#    v1 skipped a repo while a `.sync-lock` FILE existed. That was wrong both ways: a
#    marker left behind by a killed writer made the watcher skip that repo forever,
#    silently; and a writer between taking the lock and writing the file was not seen.
#  - A skip is counted. One skip is normal (a writer holds the lock for seconds);
#    a repo skipped several runs in a row is a finding — a permanent silent skip is
#    exactly the failure this watcher exists to catch.
#  - Fetch with an explicit refspec into the tracking ref, then `merge --ff-only` against
#    that ref. `git pull` reads .git/FETCH_HEAD, a file every parallel `git fetch` in the
#    clone rewrites ("Cannot fast-forward to multiple branches").
# - NO auto-commit. The only push is the unambiguous one (clean, ahead, not behind).
#  - Untracked files COUNT as dirty: in a wiki workflow, brand-new articles are the
#    normal case — an alert that ignores them misses most drift.
#  - A failed fetch is an alert, not a skip: "could not look" must never read as "fine".
#  - Repos it doesn't find are skipped silently → one list works fleet-wide.
#  - If the notify helper is missing, alerts go to stdout/cron-mail.
# Env: HYGIENE_ROOT (default ~/Developer) · HYGIENE_REPOS (space-separated names; unset = discover)
#      HYGIENE_LOCK_WAIT_S (5) · HYGIENE_SKIP_ALERT (3) · NOTIFY_HELPER
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NOTIFY="${NOTIFY_HELPER:-$HOME/bin/notify}"
NODE="$(hostname -s)"
ROOT_DIR="${HYGIENE_ROOT:-$HOME/Developer}"
# Repos: HYGIENE_REPOS (names under HYGIENE_ROOT) if set; otherwise DISCOVER every clone under
# HYGIENE_ROOT that has an `origin` remote. A hand-kept list was fail-open: the repos that
# mattered were the ones nobody added.
if [ -n "${HYGIENE_REPOS:-}" ]; then REPOS="$HYGIENE_REPOS"
else REPOS="$(for d in "$ROOT_DIR"/*/; do d="${d%/}"; git -C "$d" remote get-url origin >/dev/null 2>&1 && basename "$d"; done | tr '\n' ' ')"; fi
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/git-hygiene-lock-skips"            # repo<TAB>count
SKIP_ALERT="${HYGIENE_SKIP_ALERT:-3}"
mkdir -p "$(dirname "$STATE")"; touch "$STATE"

# shellcheck source=lib/repo-lock.sh
. "$HERE/lib/repo-lock.sh"
NOFH=""; case "$(git fetch -h 2>&1)" in *write-fetch-head*) NOFH="--no-write-fetch-head" ;; esac

ALERT=""; NEWSTATE=""
for r in $REPOS; do
  d="$ROOT_DIR/$r"
  git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || continue      # this node doesn't have it → fine
  repo_lock_release                                                  # lock of the previous repo
  rc=0; REPO_LOCK_WAIT_S="${HYGIENE_LOCK_WAIT_S:-5}" repo_lock_acquire "$d" "git-hygiene-sync" 2>/dev/null || rc=$?
  if [ "$rc" -eq 2 ]; then
    n="$(awk -F'\t' -v r="$r" '$1 == r { print $2 }' "$STATE")"; n=$(( ${n:-0} + 1 ))
    NEWSTATE="${NEWSTATE}${r}	${n}
"
    echo "skip $r (lock held by a writer; ${n}× in a row)"
    [ "$n" -ge "$SKIP_ALERT" ] && ALERT="${ALERT} ${r}(lock busy ${n} runs in a row — lsof $(repo_lock_file "$d" repo-lock))"
    continue
  elif [ "$rc" -ne 0 ]; then
    ALERT="${ALERT} ${r}(lock NOT CHECKED rc=${rc})"; continue
  fi

  br="$(git -C "$d" symbolic-ref --quiet --short HEAD)" || { ALERT="${ALERT} ${r}(detached HEAD)"; continue; }
  git -C "$d" rev-parse -q --verify "refs/remotes/origin/$br" >/dev/null || continue   # no remote branch → not shared
  git -C "$d" fetch -q $NOFH origin "+refs/heads/$br:refs/remotes/origin/$br" 2>/dev/null \
    || { ALERT="${ALERT} ${r}(fetch FAILED — not checked)"; continue; }

  # the opt-out marker is ours — it never counts as dirt (keep it out of the repo via .git/info/exclude)
  dirty="$(git -C "$d" status --porcelain --untracked-files=normal | grep -v -c ' \.hygiene-no-pull$' | tr -d ' ')"
  ahead="$(git -C "$d" rev-list --count "refs/remotes/origin/$br..HEAD")"
  behind="$(git -C "$d" rev-list --count "HEAD..refs/remotes/origin/$br")"

  if [ "$dirty" != 0 ]; then ALERT="${ALERT} ${r}(uncommitted×${dirty})"; continue; fi
  if [ "${ahead:-0}" != 0 ] && [ "${behind:-0}" != 0 ]; then ALERT="${ALERT} ${r}(diverged +${ahead}/-${behind})"; continue; fi
  if [ "${ahead:-0}" != 0 ]; then
    # clean + ahead + NOT behind: the one case where a push cannot overwrite anyone.
    # (Refusing it once left 49 commits on a single disk for five weeks.)
    if git -C "$d" push -q origin "HEAD:refs/heads/$br" 2>/dev/null; then echo "push $r (+${ahead})"
    else ALERT="${ALERT} ${r}(unpushed×${ahead}, push FAILED)"; fi
    continue
  fi
  if [ "${behind:-0}" != 0 ]; then
    if [ -e "$d/.hygiene-no-pull" ]; then
      # Opt-out: in this repo a pull IS a deploy (a service restarts on file change). Report, never pull.
      ALERT="${ALERT} ${r}(behind×${behind}, pull opted out — update deliberately)"; continue
    fi
    if git -C "$d" merge -q --ff-only "refs/remotes/origin/$br" >/dev/null 2>&1; then
      echo "ff $r (+${behind})"
    else
      ALERT="${ALERT} ${r}(non-ff)"
    fi
  fi
done
repo_lock_release
printf '%s' "$NEWSTATE" > "$STATE"        # repos not skipped this run start counting from zero again

if [ -n "$ALERT" ]; then
  MSG="Left behind → commit/push (or reconcile):${ALERT}"
  if [ -x "$NOTIFY" ]; then
    "$NOTIFY" -t "⚠️ git hygiene ${NODE}" "$MSG"
  else
    echo "⚠️ git hygiene ${NODE}: $MSG"    # cron mails stdout — never silent
  fi
fi
exit 0
