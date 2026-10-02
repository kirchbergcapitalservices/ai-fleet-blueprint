#!/bin/bash
# =============================================================================
# log-append.sh — append one entry to the wiki's append-only log.md, commit, push.
#
# Why this exists: several sessions append to log.md concurrently. `echo >> log.md`
# plus a separate commit loses entries (a parallel session commits your half-written
# append under ITS message, or an autostash pop leaves it in a stash nobody finds).
#
# The transaction:
#   1. log lock (fd 9) — orders the log appenders among themselves
#   2. transaction lock (fd 8) — orders us against every other writer of the clone
#      (both from scripts/lib/repo-lock.sh; order 9 → 8 everywhere, so no deadlock)
#   3. append, then hand over to git-safe-commit-push.sh as a CHILD process: it inherits
#      both locks (no second acquisition), commits ONLY log.md (`--only`), rebases with
#      bounded retry and checks the endpoint. Its exit codes are passed through.
#
# Two appends from two machines always touch the same place: the end of the file.
# Declare the log as a union-merge file once, and a rebase keeps BOTH entries instead
# of stopping with a conflict (order inside a log does not matter):
#     echo 'log.md merge=union' >> .gitattributes
# This script warns if that line is missing.
#
# Branch policy — log.md is a main-branch artifact. If the clone is NOT on $LOG_BRANCH:
#   LOG_APPEND_OFF_BRANCH=redirect (default): write through a throwaway worktree on
#     origin/$LOG_BRANCH; the clone's branch, index and working tree stay untouched.
#   LOG_APPEND_OFF_BRANCH=refuse: write nothing.
#   Either way, if nothing could be written, the entry goes to a spool file and the
#   script exits 7 — an entry never silently lands on a feature branch that may never merge.
#
# Usage:   log-append.sh "## YYYY-MM-DD — type — title
#          ...body..."
#          log-append.sh - < entry.md
# Env:     WIKI_DIR (default $HOME/Developer/wiki) · LOG_FILE (default log.md)
#          LOG_BRANCH (default main) · LOG_SPOOL_DIR (default $HOME/.local/state/log-spool)
# Exit:    0 pushed · 1 no entry / commit failed · 2 usage · 3 lock busy
#          4 rebase conflict — entry committed LOCALLY; a re-run does not duplicate (digest + text check), it pushes
#          5 not pushed — entry committed locally · 6 a stash was left behind (pushed or not — the message says)
#          8 UNCHECKED: pushed but the endpoint could not be re-checked, OR nothing new and the remote
#            could not be fetched to tell whether a commit is pending — do not retry blindly, look
#
# Order inside the transaction — append, then the helper fetches/rebases: both happen under the
# clone's lock, the helper rebases the log commit onto the fresh remote (union merge keeps both
# sides), and a conflict leaves the entry committed locally. Fetching BEFORE the append would not
# change any outcome and would double the network round trips; the whole-entry identity check
# below makes a re-run after any failure safe.
#          7 not written, entry spooled — off-branch (refuse mode / redirect failed), log not appendable,
#            or digest not recordable (append rolled back)
# bash 3.2-safe.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WIKI="${WIKI_DIR:-$HOME/Developer/wiki}"
LOG_FILE="${LOG_FILE:-log.md}"
LOG_BRANCH="${LOG_BRANCH:-main}"
ENTRY="${1:-}"
[ "$ENTRY" = "-" ] && ENTRY="$(cat)"
[ -n "$ENTRY" ] || { echo "⛔ log entry required (argument or '-' for stdin)" >&2; exit 1; }
ROOT="$(git -C "$WIKI" rev-parse --show-toplevel 2>/dev/null)" || { echo "⛔ $WIKI is not a git checkout" >&2; exit 2; }
cd "$ROOT" || exit 2
FIRST="$(printf '%s\n' "$ENTRY" | awk 'NF && !f { print; f = 1 }' | cut -c -120)"   # awk reads to the end: no SIGPIPE under pipefail
MSG="log: $FIRST"

# shellcheck source=lib/repo-lock.sh
. "$HERE/lib/repo-lock.sh"
repo_log_lock_acquire "$ROOT" "log-append" || exit 3
repo_lock_acquire     "$ROOT" "log-append" || exit 3

case "$(git check-attr merge -- "$LOG_FILE" 2>/dev/null)" in
  *": merge: union") ;;
  *) echo "⚠ $LOG_FILE is not 'merge=union' in .gitattributes — parallel appends from two machines will conflict" >&2 ;;
esac

spool() {   # <reason> — keep the entry, never drop it
  local d="${LOG_SPOOL_DIR:-$HOME/.local/state/log-spool}" f
  mkdir -p "$d" && f="$d/$(date -u +%Y%m%dT%H%M%SZ)-$$.md" && printf '%s\n' "$ENTRY" > "$f" \
    && echo "⛔ $1 — entry NOT written; saved to $f (replay: log-append.sh - < $f)" >&2
  exit 7
}

BR="$(git symbolic-ref --quiet --short HEAD || true)"
if [ "$BR" != "$LOG_BRANCH" ]; then
  [ "${LOG_APPEND_OFF_BRANCH:-redirect}" = redirect ] || spool "clone is on '${BR:-detached HEAD}', not $LOG_BRANCH"
  # Redirect: throwaway worktree on origin/$LOG_BRANCH. Its git children inherit our locks.
  TRACK="refs/remotes/origin/$LOG_BRANCH"
  WT="$(mktemp -d "${TMPDIR:-/tmp}/log-append-wt.XXXXXX")" || spool "no temp dir"
  rmdir "$WT"
  git fetch -q origin "+refs/heads/$LOG_BRANCH:$TRACK" && git worktree add -q --detach "$WT" "$TRACK" \
    || spool "could not create a worktree on origin/$LOG_BRANCH"
  (
    cd "$WT" || exit 1
    printf '\n%s\n' "$ENTRY" >> "$LOG_FILE" && git commit -q --only -m "$MSG" -- "$LOG_FILE" || exit 1
    for i in 1 2 3 4 5; do
      if git push -q origin "HEAD:refs/heads/$LOG_BRANCH"; then
        # endpoint check, same as the helper: re-fetch, HEAD must be on the remote branch
        if git fetch -q origin "+refs/heads/$LOG_BRANCH:$TRACK"; then
          git merge-base --is-ancestor HEAD "$TRACK" && exit 0
          echo "⛔ push said ok, but HEAD is not on origin/$LOG_BRANCH" >&2; exit 5
        fi
        echo "⚠ pushed, but the endpoint could NOT be re-checked — exit 8" >&2; exit 8
      fi
      sleep $((i * 2))
      git fetch -q origin "+refs/heads/$LOG_BRANCH:$TRACK" || continue
      git rebase -q "$TRACK" || { git rebase --abort; exit 4; }
    done
    exit 5
  )
  rc=$?
  git worktree remove --force "$WT" >/dev/null 2>&1; git worktree prune
  [ "$rc" -eq 0 ] && { echo "✓ logged via throwaway worktree onto $LOG_BRANCH (clone stays on ${BR:-detached HEAD})"; exit 0; }
  [ "$rc" -eq 8 ] && { echo "⚠ logged via throwaway worktree onto $LOG_BRANCH, endpoint UNCHECKED (exit 8)"; exit 8; }
  spool "redirect onto $LOG_BRANCH failed (rc $rc)"
fi

# Idempotent re-run: this exact entry already in the log means a previous run appended it but
# could not push (exit 4/5/8). Do NOT append again — just hand over to the helper, which pushes
# the pending local commit. (A retry after a failed fetch used to duplicate the entry.)
# Identity = a per-clone DIGEST of the exact entry text, recorded BEFORE the commit, AND the text
# still being in the file. Text containment alone cannot be made exact for multi-line entries
# (a shorter entry that is a prefix of a longer one — even with newline framing — read as
# "present"; found by review). The digest file lives in the git dir of this clone: a re-run on
# this clone after exit 4/5/8 finds it; a different entry never matches it. A header alone is
# not an identity either: two entries may share a date/type/title and differ in body. Leading blank lines are stripped first so an entry that
# starts with a newline is not mistaken for "already present" by matching an empty line.
ENTRY="$(printf '%s\n' "$ENTRY" | sed '/./,$!d')"
ENTRY="${ENTRY%"${ENTRY##*[![:space:]]}"}"   # drop trailing whitespace too
[ -n "$ENTRY" ] || { echo "⛔ empty entry" >&2; exit 1; }
DIGEST="$(printf '%s' "$ENTRY" | shasum -a 256 | cut -c1-64)"
DFILE="$(git rev-parse --git-dir)/log-append.digests"
if grep -qx -- "$DIGEST" "$DFILE" 2>/dev/null \
   && E="$ENTRY" /usr/bin/perl -0777 -ne 'exit(index($_, $ENV{E}) >= 0 ? 0 : 1)' "$LOG_FILE" 2>/dev/null; then
  echo "ℹ this exact entry was already appended by this clone — not appended again; pushing what is pending" >&2
  exec "$HERE/git-safe-commit-push.sh" "$ROOT" "$MSG" "$LOG_FILE"
fi
if ! git diff --quiet -- "$LOG_FILE" || ! git diff --cached --quiet -- "$LOG_FILE"; then
  echo "⚠ $LOG_FILE already had uncommitted changes — they go into this commit too" >&2
fi
# Append FIRST, then record the digest: the digest must only ever exist for an entry that is in
# the file (a digest written before a failed append let a later replay skip the entry — found by
# review). If the digest cannot be recorded, the append is rolled back (truncate to the old size)
# and the entry is spooled; nothing half-done is left behind.
OLDSIZE="$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ')"; OLDSIZE="${OLDSIZE:-0}"
printf '\n%s\n' "$ENTRY" >> "$LOG_FILE" || spool "could not append to $LOG_FILE"
if ! printf '%s\n' "$DIGEST" >> "$DFILE" 2>/dev/null; then
  /usr/bin/perl -e 'truncate($ARGV[0], $ARGV[1]) or exit 1' "$LOG_FILE" "$OLDSIZE" \
    || { echo "⛔ digest not recorded AND the append could not be rolled back — $LOG_FILE has an uncommitted entry without digest" >&2; exit 1; }
  spool "could not record the entry digest in $DFILE"
fi
# The child inherits fd 8 + 9: git-safe-commit-push.sh sees the inherited lock and does not wait for us.
"$HERE/git-safe-commit-push.sh" "$ROOT" "$MSG" "$LOG_FILE"
