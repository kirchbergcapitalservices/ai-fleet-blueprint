#!/bin/bash
# =============================================================================
# repo-lock.sh — one kernel-held transaction lock per clone. SOURCE this file.
#
# Who must hold it: everyone who changes HEAD, the index or the working tree of
# a clone — commit, rebase, merge, pull, push-with-rebase. The helpers in this
# repo take it (git-safe-commit-push.sh, log-append.sh, git-hygiene-sync.sh);
# a direct `git commit` takes it through the versioned pre-commit hook.
#
# WHY flock and not a PID/noclobber lock file (the v1 design of this repo):
#   A lock FILE can only be cleaned up with DERIVED evidence — "the PID is dead",
#   "the file is older than 5 minutes". Every one of those proofs can be wrong:
#   · kill -9 of the script leaves its `git push` child running: PID dead,
#     lock "free", a second writer starts while the first one still writes;
#   · a slow push (> 5 min) gets its lock stolen by the age rule;
#   · two cleaners see the same dead PID; the second deletes the lock the
#     first one just took — check-then-delete is never atomic;
#   · a recycled PID looks like a live holder.
#   flock(2) has none of these: the lock belongs to the OPEN FILE DESCRIPTION.
#   It is inherited by children (git commit/push keep holding it until THEY
#   finish, even after kill -9 of the parent), and the kernel drops it when the
#   last holder exits. There is no stale state, so there is nothing to clean up,
#   no PID question and no age question.
#
# MECHANICS
#   · Lock file: <git-dir>/repo-lock.flock (optional log lock: <git-dir>/repo-log.flock).
#     It lives inside the git dir — never in the working tree, never in `git status`,
#     never deleted (deleting a lock file while someone holds it is its own race).
#   · macOS ships no flock(1) command. The lock is taken on a file descriptor that
#     bash opens (`exec 8>>file`); a short /usr/bin/perl call runs flock(2) on that
#     inherited fd and exits. flock locks belong to the open file description, which
#     bash still holds, so the lock survives perl's exit. On Linux, flock(1) is used
#     when present (`flock -w N 8` does exactly the same on the same fd).
#   · Waiting: up to REPO_LOCK_WAIT_S seconds (default 90; 0 = do not wait), then
#     rc 2 with a diagnosis. A holder is NEVER evicted, not even after hours. If a
#     process truly hangs, a human ends it: `lsof <git-dir>/repo-lock.flock` lists
#     every holder, including children.
#   · Info marker: <git-dir>/repo-lock.holder = "PID|epoch|description". Pure
#     information for humans; it has no locking effect. Deleting it breaks nothing;
#     after a kill -9 the next holder overwrites it. (v1 kept `.sync-lock` in the
#     working tree; a leftover there shows up as untracked dirt and was read as
#     "locked" by the hygiene watcher forever.)
#   · Inherited lock: if fd 8 of this process already points to the lock file
#     (inode comparison, no lock operation), a holder called us — a hook, a helper
#     run by another helper. We pass through instead of waiting for our own parent.
#   · Long-lived children inherit the lock too. `git gc --auto` detaches into the
#     background WITHOUT closing fds and would keep the lock after the script ends,
#     so holders run git with gc.autoDetach=false. Do not start daemons while holding.
#   · Linked worktrees SHARE the lock: it lives in the common git dir (`git rev-parse
#     --git-common-dir`), because worktrees share refs/stash, the index locks and the objects.
#   · Upgrading from the v1 noclobber lock: the old scripts cannot see the flock and
#     the new ones ignore `.sync-lock`. Stop all writers on the node, deploy, restart.
#
# USAGE    . scripts/lib/repo-lock.sh
#          repo_log_lock_acquire "$REPO" "<what>"   # optional, fd 9 — ALWAYS before the next one
#          repo_lock_acquire     "$REPO" "<what>"   # transaction lock, fd 8
#          ...                                       # released by the EXIT/INT/TERM trap, or:
#          repo_lock_release
#          repo_lock_held "$REPO"                    # rc 0 if fd 8 was inherited from a holder
# ORDER    Where both are held: log lock (9) BEFORE transaction lock (8). Never the
#          other way round — that ordering is what makes deadlocks impossible.
# TRAPS    acquire installs EXIT/INT/TERM traps that release. Set REPO_LOCK_NO_TRAP=1
#          if your script owns those traps; then call repo_lock_release yourself.
# RC       0 held (or inherited) · 1 lock file cannot be created · 2 still busy after
#          REPO_LOCK_WAIT_S · 4 lock tool failed = NOT CHECKED, treat as busy
# bash 3.2-safe, set -e/-u-safe.
# =============================================================================

# /usr/bin/perl, not whatever `perl` is first on PATH: a lock that a PATH entry can replace is no lock.
REPO_LOCK_PERL="${REPO_LOCK_PERL:-/usr/bin/perl}"
[ -n "${REPO_LOCK_FDS[*]+x}" ] || REPO_LOCK_FDS=()     # fds held by THIS process, acquisition order
[ -n "${REPO_LOCK_MARKERS[*]+x}" ] || REPO_LOCK_MARKERS=()

repo_lock_file() {   # <repo> <name: repo-lock|repo-log> -> absolute path of the lock file
  local gd
  # COMMON git dir, not the worktree's own: linked worktrees share refs/stash, the index locks
  # and the object store, so they must share the transaction lock too (a per-worktree lock let two
  # worktrees race on the shared stash list — found by review).
  gd="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$gd" in /*) ;; *) gd="$1/$gd" ;; esac
  gd="$(cd "$gd" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s.flock\n' "$gd" "$2"
}

# rc 0 if fd $1 of this process is open AND refers to file $2 (same device + inode).
repo_lock_fd_is_file() {
  "$REPO_LOCK_PERL" -e 'my ($fd,$f)=@ARGV; open(my $h,"<&=",$fd) or exit 1;
    my @a=stat($h); my @b=stat($f); exit((@a && @b && $a[0]==$b[0] && $a[1]==$b[1]) ? 0 : 1)' \
    -- "$1" "$2" 2>/dev/null
}

# Low level: lock the already-open fd $1, waiting up to $2 s. rc 0 locked · 2 busy · 4 tool failed.
repo_lock_flock_fd() {
  local fd="$1" w="$2" rc
  if command -v flock >/dev/null 2>&1; then              # Linux util-linux
    if [ "$w" -le 0 ]; then flock -n "$fd"; else flock -w "$w" "$fd"; fi
    rc=$?; [ "$rc" -eq 0 ] && return 0; [ "$rc" -eq 1 ] && return 2; return 4
  fi
  "$REPO_LOCK_PERL" -e '
    use Fcntl qw(:flock); my ($fd, $w) = @ARGV;
    open(my $h, ">>&=", $fd) or exit 4;
    if ($w <= 0) { exit(flock($h, LOCK_EX | LOCK_NB) ? 0 : 2); }
    $SIG{ALRM} = sub { exit 2 }; alarm $w;
    exit(flock($h, LOCK_EX) ? 0 : 2);' -- "$fd" "$w"
}

repo_lock_diagnose() {   # <marker> <lockfile> <waited>
  local pid="" ts="" desc="" now
  now="$(date +%s)"
  IFS='|' read -r pid ts desc 2>/dev/null < "$1" || true
  case "$ts" in ''|*[!0-9]*) ts="$now" ;; esac
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "⛔ repo lock busy for ${3}s — holder PID $pid is alive ($desc, since $((now - ts))s)." >&2
  elif [ -n "$pid" ]; then
    echo "⛔ repo lock busy for ${3}s — marker names PID $pid (dead): a child (git commit/push) still holds it." >&2
  else
    echo "⛔ repo lock busy for ${3}s — no marker (holder between lock and marker, or marker deleted)." >&2
  fi
  echo "   Not taken over — a holder is never evicted. See holders: lsof \"$2\"" >&2
}

repo_lock_acquire_named() {   # <repo> <name> <desc> <fd>
  local repo="$1" name="$2" desc="${3:-}" fd="$4" wait_s="${REPO_LOCK_WAIT_S:-90}" lf marker rc
  case "$wait_s" in ''|*[!0-9]*) wait_s=90 ;; esac
  lf="$(repo_lock_file "$repo" "$name")" || { echo "⛔ repo lock: $repo is not a git checkout" >&2; return 1; }
  marker="${lf%.flock}.holder"

  # Inherited from a holder (we are its child): part of its transaction, not a second acquisition.
  if repo_lock_fd_is_file "$fd" "$lf"; then return 0; fi

  ( : >> "$lf" ) 2>/dev/null || { echo "⛔ repo lock: cannot create $lf" >&2; return 1; }
  eval "exec $fd>>\"\$lf\""
  repo_lock_flock_fd "$fd" "$wait_s"; rc=$?
  if [ "$rc" -ne 0 ]; then
    eval "exec $fd>&-"
    if [ "$rc" -eq 2 ]; then repo_lock_diagnose "$marker" "$lf" "$wait_s"; return 2; fi
    echo "⛔ repo lock: flock tool failed (rc $rc) — NOT CHECKED, treated as busy." >&2
    return 4
  fi

  REPO_LOCK_FDS+=("$fd"); REPO_LOCK_MARKERS+=("$marker")
  export GIT_CONFIG_PARAMETERS="${GIT_CONFIG_PARAMETERS:+$GIT_CONFIG_PARAMETERS }'gc.autoDetach=false'"
  printf '%s|%s|%s\n' "$$" "$(date +%s)" "$desc" > "$marker" 2>/dev/null || true
  if [ "${REPO_LOCK_NO_TRAP:-0}" != 1 ]; then
    trap 'repo_lock_release' EXIT
    trap 'repo_lock_release; exit 130' INT
    trap 'repo_lock_release; exit 143' TERM
  fi
  return 0
}

repo_lock_release() {   # releases every lock this process acquired, last one first
  local i fd marker
  i=${#REPO_LOCK_FDS[@]}
  while [ "$i" -gt 0 ]; do
    i=$((i - 1)); fd="${REPO_LOCK_FDS[$i]}"; marker="${REPO_LOCK_MARKERS[$i]}"
    [ -f "$marker" ] && [ "$(cut -d'|' -f1 "$marker" 2>/dev/null)" = "$$" ] && rm -f "$marker"
    case "$fd" in ''|*[!0-9]*) continue ;; esac      # only digits may ever follow `exec`
    eval "exec ${fd}>&-"
  done
  REPO_LOCK_FDS=(); REPO_LOCK_MARKERS=()
}

repo_lock_acquire()     { repo_lock_acquire_named "$1" repo-lock "${2:-}" 8; }
repo_log_lock_acquire() { repo_lock_acquire_named "$1" repo-log  "${2:-}" 9; }
repo_lock_held()        { local lf; lf="$(repo_lock_file "$1" repo-lock)" || return 1; repo_lock_fd_is_file 8 "$lf"; }

# git with a short retry on index.lock: a direct `git commit` holds index.lock WHILE its
# pre-commit hook waits for our lock (an inversion that resolves itself when the hook gives
# up). Helpers that hold the lock call git through this. Retries for REPO_INDEXLOCK_RETRY_S.
repo_git_idx() {
  local n=0 max="${REPO_INDEXLOCK_RETRY_S:-30}" tmp rc
  tmp="$(mktemp "${TMPDIR:-/tmp}/repo-git.XXXXXX")" || { git "$@"; return $?; }
  while :; do
    git "$@" 2>"$tmp"; rc=$?
    if [ "$rc" -eq 128 ] && grep -q 'index.lock' "$tmp" 2>/dev/null && [ "$n" -lt "$max" ]; then
      n=$((n + 1)); sleep 1; continue
    fi
    cat "$tmp" >&2; rm -f "$tmp"; return "$rc"
  done
}
