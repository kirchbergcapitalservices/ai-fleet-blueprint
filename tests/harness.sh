#!/bin/bash
# =============================================================================
# tests/harness.sh — functional tests for the lock + write scripts.
#
# Everything runs in throwaway repos under `mktemp -d`: a bare repo is `origin`
# (no network), HOME points into the test tree, the global/system git config is
# switched off (GIT_CONFIG_GLOBAL=/dev/null), and git speaks English (LC_ALL=C)
# so no assertion depends on the machine's language. Never point this at a real clone.
#
# Usage:  bash tests/harness.sh            (KEEP=1 keeps the temp dir for inspection)
# Exit:   0 all passed · 1 at least one failure
# =============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$(cd "$HERE/../scripts" && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/fleet-harness.XXXXXX")" || { echo "cannot create temp dir — aborting, nothing tested" >&2; exit 1; }
export HOME="$T/home" XDG_STATE_HOME="$T/state" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 LC_ALL=C
export GIT_AUTHOR_NAME=fleet-bot GIT_AUTHOR_EMAIL=fleet-bot@example.invalid
export GIT_COMMITTER_NAME=fleet-bot GIT_COMMITTER_EMAIL=fleet-bot@example.invalid
export GIT_IDENT=fleet-bot@example.invalid NOTIFY_HELPER=/nonexistent
mkdir -p "$HOME"
cleanup() { jobs -p | xargs kill 2>/dev/null; [ "${KEEP:-0}" = 1 ] && echo "kept: $T" || rm -rf "$T"; }
trap cleanup EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS  $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $*"; }
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }
now() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%.1f\n", time'; }
elapsed_ge() { /usr/bin/perl -e 'exit(($ARGV[1]-$ARGV[0]) >= $ARGV[2] ? 0 : 1)' "$1" "$2" "$3"; }
elapsed_lt() { /usr/bin/perl -e 'exit(($ARGV[1]-$ARGV[0]) <  $ARGV[2] ? 0 : 1)' "$1" "$2" "$3"; }

# world <name>: bare origin + clones A and B, seeded with log.md (merge=union) and a.md
world() {
  W="$T/$1"; mkdir -p "$W"
  git init -q --bare "$W/origin.git"; git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
  git init -q "$W/seed"; git -C "$W/seed" checkout -q -b main
  printf '# log\n' > "$W/seed/log.md"; printf 'a\n' > "$W/seed/a.md"
  printf 'log.md merge=union\n.holder\n' > "$W/seed/.gitattributes"
  git -C "$W/seed" add -A; git -C "$W/seed" commit -q -m seed
  git -C "$W/seed" remote add origin "$W/origin.git"; git -C "$W/seed" push -q origin main
  git clone -q "$W/origin.git" "$W/A"; git clone -q "$W/origin.git" "$W/B"
}
on_origin() { git -C "$W/origin.git" show "main:$1" 2>/dev/null; }
# holder <repo> <seconds>: a separate process that holds the repo lock (its PID → $HOLDER)
holder() {
  ( . "$S/lib/repo-lock.sh"; repo_lock_acquire "$1" "test-holder" || exit 9; exec sleep "$2" ) &   # exec: the holder IS the sleeper
  HOLDER=$!
  local n=0; while [ ! -f "$(git -C "$1" rev-parse --git-common-dir)/repo-lock.holder" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
}
slow_push_hook() { printf '#!/bin/sh\nsleep %s\n' "$2" > "$1/.git/hooks/pre-push"; chmod +x "$1/.git/hooks/pre-push"; }

echo "== T1 happy path: commit + push"
world t1
echo new > "$W/A/n.md"
"$S/git-safe-commit-push.sh" "$W/A" "add n" n.md >/dev/null 2>&1; rc=$?
check "rc 0" '[ $rc -eq 0 ]'
check "file on origin" '[ "$(on_origin n.md)" = new ]'
check "clone clean, not ahead" '[ -z "$(git -C "$W/A" status --porcelain)" ] && [ "$(git -C "$W/A" rev-list --count origin/main..HEAD)" = 0 ]'

echo "== T2 nothing to commit"
before="$(git -C "$W/origin.git" rev-parse main)"
out="$("$S/git-safe-commit-push.sh" "$W/A" "noop" a.md 2>&1)"; rc=$?
check "rc 0" '[ $rc -eq 0 ]'
check "says nothing to commit" 'printf "%s" "$out" | grep -q "nothing to commit"'
check "origin unchanged" '[ "$(git -C "$W/origin.git" rev-parse main)" = "$before" ]'

echo "== T3 two writers on one clone at the same time: second waits, both land"
world t3; slow_push_hook "$W/A" 2
echo x > "$W/A/x.md"; echo y > "$W/A/y.md"
t0="$(now)"
"$S/git-safe-commit-push.sh" "$W/A" "add x" x.md > "$T/out-t3x" 2>&1 & p1=$!
"$S/git-safe-commit-push.sh" "$W/A" "add y" y.md > "$T/out-t3y" 2>&1 & p2=$!
wait $p1; r1=$?; wait $p2; r2=$?; t1="$(now)"
check "both rc 0" '[ $r1 -eq 0 ] && [ $r2 -eq 0 ]'
check "both files on origin" '[ "$(on_origin x.md)" = x ] && [ "$(on_origin y.md)" = y ]'
check "serialized (2 slow pushes took >= 4 s)" 'elapsed_ge "$t0" "$t1" 4'
one_file_each() { local c; for c in $(git -C "$W/origin.git" rev-list -2 main); do git -C "$W/origin.git" show --name-only --format= "$c" | grep . | tr "\n" " "; echo; done | sort | tr -d "\n"; }
check "each commit has exactly its own file" '[ "$(one_file_each)" = "x.md y.md " ]'

echo "== T4 rebase conflict: exit 4, working tree unchanged, nothing overwritten"
world t4
echo "from B" > "$W/B/a.md"; "$S/git-safe-commit-push.sh" "$W/B" "B edits a" a.md >/dev/null 2>&1
echo "from A" > "$W/A/a.md"; echo "other session wip" > "$W/A/log.md"
sum_before="$(cd "$W/A" && cat a.md log.md | shasum)"
"$S/git-safe-commit-push.sh" "$W/A" "A edits a" a.md > "$T/out-t4" 2>&1; rc=$?
check "rc 4" '[ $rc -eq 4 ]'
check "files in working tree unchanged" '[ "$(cd "$W/A" && cat a.md log.md | shasum)" = "$sum_before" ]'
check "origin keeps B's version" '[ "$(on_origin a.md)" = "from B" ]'
check "no rebase in progress, no stash left" '[ ! -d "$W/A/.git/rebase-merge" ] && [ -z "$(git -C "$W/A" stash list)" ]'

echo "== T5 a dead holder holds nothing (positive control against the PID/age lock)"
world t5
holder "$W/A" 300; kill -9 "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
echo z > "$W/A/z.md"; t0="$(now)"
REPO_LOCK_WAIT_S=10 "$S/git-safe-commit-push.sh" "$W/A" "add z" z.md >/dev/null 2>&1; rc=$?; t1="$(now)"
check "killed holder: next writer gets through at once (< 3 s)" '[ $rc -eq 0 ] && elapsed_lt "$t0" "$t1" 3'
check "stale marker of the dead holder did not block" '[ "$(on_origin z.md)" = z ]'
# T5b: the parent is killed while its CHILD (stand-in for `git push`) still runs. The child
# inherited the lock, so the next writer must wait for the child — and not a second longer.
( . "$S/lib/repo-lock.sh"; repo_lock_acquire "$W/A" "parent"; sleep 3 & wait ) & P=$!
sleep 0.5; { kill -9 "$P"; wait "$P"; } 2>/dev/null   # quiet: no "Killed: 9" job notice
echo w > "$W/A/w.md"; t0="$(now)"
REPO_LOCK_WAIT_S=10 "$S/git-safe-commit-push.sh" "$W/A" "add w" w.md >/dev/null 2>&1; rc=$?; t1="$(now)"
check "parent dead, child alive: writer waited for the child (>= 2 s), then passed" '[ $rc -eq 0 ] && elapsed_ge "$t0" "$t1" 2'
# Control: the SAME scenario under the v1 rule ("holder PID dead → lock is free"). The v1
# lock file names the killed parent; its child is still writing — and v1 hands the lock out.
sh -c 'set -C; echo "$$|$(date +%s)|v1" > "$1"; sleep 3 & echo $! > "$2"; wait' _ "$T/v1.lock" "$T/v1.child" & P=$!
sleep 0.5; kill -9 "$P" 2>/dev/null; wait "$P" 2>/dev/null
v1_pid="$(cut -d'|' -f1 "$T/v1.lock")"
kill -0 "$v1_pid" 2>/dev/null || rm -f "$T/v1.lock"                      # v1 stale-lock cleanup, verbatim logic
if ( set -o noclobber; echo "$$|$(date +%s)|next" > "$T/v1.lock" ) 2>/dev/null && kill -0 "$(cat "$T/v1.child")" 2>/dev/null; then v1_stolen=1; else v1_stolen=0; fi
check "control: v1 rule gives the lock away while the child still writes" '[ $v1_stolen = 1 ]'

echo "== T6 log-append twice in parallel: two entries, no loss"
world t6; slow_push_hook "$W/A" 1
WIKI_DIR="$W/A" "$S/log-append.sh" "## e1 — first" > "$T/out-t6a" 2>&1 & p1=$!
WIKI_DIR="$W/A" "$S/log-append.sh" "## e2 — second" > "$T/out-t6b" 2>&1 & p2=$!
wait $p1; r1=$?; wait $p2; r2=$?
check "both rc 0" '[ $r1 -eq 0 ] && [ $r2 -eq 0 ]'
check "both entries exactly once on origin" '[ "$(on_origin log.md | grep -c "^## e1 — first$")" = 1 ] && [ "$(on_origin log.md | grep -c "^## e2 — second$")" = 1 ]'
# T6b: two MACHINES (clones) append at once — merge=union keeps both instead of a conflict
WIKI_DIR="$W/A" "$S/log-append.sh" "## e3 — from A" >/dev/null 2>&1 & p1=$!
WIKI_DIR="$W/B" "$S/log-append.sh" "## e4 — from B" >/dev/null 2>&1 & p2=$!
wait $p1; r1=$?; wait $p2; r2=$?
check "two clones: both rc 0, both entries on origin" '[ $r1 -eq 0 ] && [ $r2 -eq 0 ] && on_origin log.md | grep -q "^## e3" && on_origin log.md | grep -q "^## e4"'

# T6c: the APPEND itself happens under the lock — while another writer holds it, log.md is not touched
holder "$W/A" 30
sum0="$(shasum < "$W/A/log.md")"
REPO_LOCK_WAIT_S=1 WIKI_DIR="$W/A" "$S/log-append.sh" "## e7 — must wait" >/dev/null 2>&1; rc=$?
check "lock busy: rc 3 and log.md untouched" '[ $rc -eq 3 ] && [ "$(shasum < "$W/A/log.md")" = "$sum0" ]'
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

echo "== T7 pre-commit: blocks a foreign holder, lets the own helper through"
world t7
inst="$("$S/hooks/install.sh" "$W/A" 2>&1)"; "$S/hooks/install.sh" --check "$W/A" >/dev/null 2>&1; crc=$?
check "installer: symlinks, --check rc 0" '[ $crc -eq 0 ] && [ -L "$W/A/.git/hooks/pre-commit" ]'
holder "$W/A" 30
echo d > "$W/A/d.md"; git -C "$W/A" add d.md
out="$(cd "$W/A" && REPO_LOCK_HOOK_WAIT_S=1 git commit -q -m direct 2>&1)"; rc=$?
check "direct commit blocked while a foreign holder holds" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "COMMIT BLOCKED"'
check "nothing was committed" '[ "$(git -C "$W/A" rev-list --count origin/main..HEAD)" = 0 ]'
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
echo h > "$W/A/h.md"
"$S/git-safe-commit-push.sh" "$W/A" "helper commit" h.md >/dev/null 2>&1; rc=$?
check "helper's own commit passes its hook (inherited lock)" '[ $rc -eq 0 ] && [ "$(on_origin h.md)" = h ]'
out="$(cd "$W/A" && git commit -q -m direct2 2>&1)"; rc=$?
check "direct commit passes when nobody holds" '[ $rc -eq 0 ]'
sleep 0.5
check "keeper released the lock after git exited" '( . "$S/lib/repo-lock.sh"; REPO_LOCK_WAIT_S=0 repo_lock_acquire "$W/A" probe 2>/dev/null )'
ln -sfn /nonexistent/pre-commit "$W/A/.git/hooks/pre-rebase"
"$S/hooks/install.sh" --check "$W/A" >/dev/null 2>&1; crc=$?
check "--check reports a dangling/foreign hook (git itself would stay silent)" '[ $crc -ne 0 ]'

echo "== T8 hygiene: skips a held repo (and counts), pulls once it is free"
world t8
echo up > "$W/B/u.md"; "$S/git-safe-commit-push.sh" "$W/B" "B ahead" u.md >/dev/null 2>&1
holder "$W/A" 30
out="$(HYGIENE_ROOT="$W" HYGIENE_REPOS=A HYGIENE_LOCK_WAIT_S=1 "$S/git-hygiene-sync.sh" 2>&1)"
check "skipped while held" 'printf "%s" "$out" | grep -q "skip A (lock held"'
check "did not touch the clone (still behind)" '[ ! -f "$W/A/u.md" ]'
out="$(HYGIENE_ROOT="$W" HYGIENE_REPOS=A HYGIENE_LOCK_WAIT_S=1 HYGIENE_SKIP_ALERT=2 "$S/git-hygiene-sync.sh" 2>&1)"
check "second skip in a row raises an alert" 'printf "%s" "$out" | grep -q "lock busy 2 runs in a row"'
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
out="$(HYGIENE_ROOT="$W" HYGIENE_REPOS=A HYGIENE_LOCK_WAIT_S=1 "$S/git-hygiene-sync.sh" 2>&1)"
check "free again: fast-forwarded" '[ -f "$W/A/u.md" ] && printf "%s" "$out" | grep -q "ff A"'
check "skip counter reset" '! grep -q "^A	" "$XDG_STATE_HOME/git-hygiene-lock-skips"'

echo "== T16 log-append identity: re-run of the SAME entry appends nothing; a DIFFERENT body with the same header is a new entry"
world t16
E1="## 2026-01-01 — test — same header
body one"
E2="## 2026-01-01 — test — same header
body two"
WIKI_DIR="$W/A" "$S/log-append.sh" "$E1" >/dev/null 2>&1
WIKI_DIR="$W/A" "$S/log-append.sh" "$E1" >/dev/null 2>&1; rc=$?
check "same entry twice → rc 0, exactly one copy on origin" '[ $rc -eq 0 ] && [ "$(on_origin log.md | grep -c "body one")" = 1 ]'
WIKI_DIR="$W/A" "$S/log-append.sh" "$E2" >/dev/null 2>&1
check "different body, same header → second entry on origin" '[ "$(on_origin log.md | grep -c "body two")" = 1 ]'
WIKI_DIR="$W/A" "$S/log-append.sh" "
$E1" >/dev/null 2>&1
check "leading blank line does not fool the identity check" '[ "$(on_origin log.md | grep -c "body one")" = 1 ]'
E3="## 2026-01-01 — test — same header
body one extended"
WIKI_DIR="$W/A" "$S/log-append.sh" "$E3" >/dev/null 2>&1
E4="## 2026-01-02 — test — prefix
alpha beta"
WIKI_DIR="$W/A" "$S/log-append.sh" "$E4 gamma" >/dev/null 2>&1    # the LONGER entry first
WIKI_DIR="$W/A" "$S/log-append.sh" "$E4" >/dev/null 2>&1          # then its prefix
check "a shorter entry that is a prefix of a longer one is NOT 'already present'" '[ "$(on_origin log.md | grep -c "^alpha beta$")" = 1 ] && [ "$(on_origin log.md | grep -c "^alpha beta gamma$")" = 1 ]'
E5="## 2026-01-03 — test — multiline prefix
line one
line two"
WIKI_DIR="$W/A" "$S/log-append.sh" "$E5
line three" >/dev/null 2>&1       # the LONGER (three-line) entry first
WIKI_DIR="$W/A" "$S/log-append.sh" "$E5" >/dev/null 2>&1   # then the two-line prefix ending at a newline
check "multi-line prefix entry is appended, not swallowed" '[ "$(on_origin log.md | grep -c "^line two$")" = 2 ] && [ "$(on_origin log.md | grep -c "^line three$")" = 1 ]'

echo "== T21 log-append: digest cannot be recorded → nothing appended, entry spooled (rc 7)"
world t21
mkdir -p "$W/A/.git/log-append.digests"          # a DIRECTORY where the digest file must be → write fails
WIKI_DIR="$W/A" LOG_SPOOL_DIR="$T/spool21" "$S/log-append.sh" "## t21 — digest
d body" >/dev/null 2>&1; rc=$?
check "rc 7, log.md untouched, entry spooled" '[ $rc -eq 7 ] && ! grep -q "d body" "$W/A/log.md" && grep -rq "d body" "$T/spool21"'

echo "== T22 log-append: log.md not appendable → rc 7, spooled, and NO digest left behind (replay must not skip it)"
world t22
chmod 444 "$W/A/log.md"
WIKI_DIR="$W/A" LOG_SPOOL_DIR="$T/spool22" "$S/log-append.sh" "## t22 — ro
ro body" >/dev/null 2>&1; rc=$?
chmod 644 "$W/A/log.md"
check "rc 7 and entry spooled" '[ $rc -eq 7 ] && grep -rq "ro body" "$T/spool22"'
check "no digest recorded for the unwritten entry" '! grep -q "$(printf "%s" "## t22 — ro
ro body" | shasum -a 256 | cut -c1-64)" "$W/A/.git/log-append.digests" 2>/dev/null'
WIKI_DIR="$W/A" "$S/log-append.sh" "## t22 — ro
ro body" >/dev/null 2>&1
check "replay after the failure appends the entry" '[ "$(on_origin log.md | grep -c "^ro body$")" = 1 ]'

echo "== T20 log-append: fetch fails → entry committed locally (rc 5); re-run of the SAME entry pushes it ONCE"
world t20
mv "$W/origin.git" "$W/origin.gone"
WIKI_DIR="$W/A" GSCP_MAXTRIES=1 "$S/log-append.sh" "## t20 — retry
retry body" >/dev/null 2>&1; rc1=$?
mv "$W/origin.gone" "$W/origin.git"
WIKI_DIR="$W/A" "$S/log-append.sh" "## t20 — retry
retry body" >/dev/null 2>&1; rc2=$?
check "first run rc 5 (committed locally), second run rc 0" '[ $rc1 -eq 5 ] && [ $rc2 -eq 0 ]'
check "exactly one copy on origin after the retry" '[ "$(on_origin log.md | grep -c "^retry body$")" = 1 ]'

echo "== T18 nothing new staged + remote unreachable → exit 8 (pending state unchecked), never 0"
world t18
echo p > "$W/A/p.md"; git -C "$W/A" add p.md; git -C "$W/A" commit -q -m "local p"
mv "$W/origin.git" "$W/origin.gone"
GSCP_MAXTRIES=1 "$S/git-safe-commit-push.sh" "$W/A" "p" p.md >/dev/null 2>&1; rc=$?
mv "$W/origin.gone" "$W/origin.git"
check "rc 8 with a pending commit and no reachable remote" '[ $rc -eq 8 ]'
GSCP_MAXTRIES=1 "$S/git-safe-commit-push.sh" "$W/A" "p" p.md >/dev/null 2>&1   # push the pending commit now that origin is back
mv "$W/origin.git" "$W/origin.gone"
GSCP_MAXTRIES=1 "$S/git-safe-commit-push.sh" "$W/A" "p again" p.md >/dev/null 2>&1; rc=$?
mv "$W/origin.gone" "$W/origin.git"
check "rc 8 with NOTHING pending and no reachable remote (never 0)" '[ $rc -eq 8 ]'
GSCP_DRYRUN=1 "$S/git-safe-commit-push.sh" "$W/A" "x" does-not-exist.md >/dev/null 2>&1; rc=$?
check "dry-run with a bad pathspec → rc 2, not 0" '[ $rc -eq 2 ]'

echo "== T19 off-branch redirect: endpoint re-check impossible after push → exit 8, entry IS on origin/main"
world t19
git -C "$W/A" checkout -q -b feature
printf '#!/bin/sh\nmv "$GIT_DIR" "$GIT_DIR.away" 2>/dev/null || mv "$(pwd)" "$(pwd).away"\n' > "$W/origin.git/hooks/post-update"; chmod +x "$W/origin.git/hooks/post-update"
WIKI_DIR="$W/A" "$S/log-append.sh" "## t19 — redirect
e8body" >/dev/null 2>&1; rc=$?
mv "$W/origin.git.away" "$W/origin.git" 2>/dev/null
check "rc 8 and the entry is on origin/main" '[ $rc -eq 8 ] && on_origin log.md | grep -q "^e8body$"'

echo "== T17 endpoint re-check impossible after a successful push → exit 8 (pushed, UNCHECKED), never 0"
world t17
printf '#!/bin/sh\nmv "$GIT_DIR" "$GIT_DIR.away" 2>/dev/null || mv "$(pwd)" "$(pwd).away"\n' > "$W/origin.git/hooks/post-update"; chmod +x "$W/origin.git/hooks/post-update"
echo e8 > "$W/A/e8.md"
GSCP_MAXTRIES=1 "$S/git-safe-commit-push.sh" "$W/A" "e8" e8.md >/dev/null 2>&1; rc=$?
mv "$W/origin.git.away" "$W/origin.git" 2>/dev/null
check "rc 8 and the commit IS on origin" '[ $rc -eq 8 ] && [ "$(on_origin e8.md)" = e8 ]'

echo "== T14 hygiene: clean + ahead + not behind → pushed; diverged → alert, nothing pushed"
world t14
echo ahead > "$W/A/h.md"; git -C "$W/A" add h.md; git -C "$W/A" commit -q -m "local only"
out="$(HYGIENE_ROOT="$W" HYGIENE_REPOS=A HYGIENE_LOCK_WAIT_S=1 "$S/git-hygiene-sync.sh" 2>&1)"
check "pushed the clean-ahead clone" 'printf "%s" "$out" | grep -q "push A (+1)" && [ "$(on_origin h.md)" = ahead ]'
echo other > "$W/B/o.md"; "$S/git-safe-commit-push.sh" "$W/B" "B o" o.md >/dev/null 2>&1
echo more > "$W/A/m2.md"; git -C "$W/A" add m2.md; git -C "$W/A" commit -q -m "A m2"
out="$(HYGIENE_ROOT="$W" HYGIENE_REPOS=A HYGIENE_LOCK_WAIT_S=1 "$S/git-hygiene-sync.sh" 2>&1)"
check "diverged clone: alert, not pushed" 'printf "%s" "$out" | grep -q "diverged" && [ -z "$(on_origin m2.md)" ]'

echo "== T15 hygiene: opt-out marker — behind clone is reported, never pulled; discovery finds clones"
world t15
echo up > "$W/B/u.md"; "$S/git-safe-commit-push.sh" "$W/B" "B up" u.md >/dev/null 2>&1
touch "$W/A/.hygiene-no-pull"
out="$(HYGIENE_ROOT="$W" HYGIENE_REPOS=A HYGIENE_LOCK_WAIT_S=1 "$S/git-hygiene-sync.sh" 2>&1)"
check "opted-out clone not pulled, alert says so" '[ ! -f "$W/A/u.md" ] && printf "%s" "$out" | grep -q "pull opted out"'
rm -f "$W/A/.hygiene-no-pull"
out="$(HYGIENE_ROOT="$W" HYGIENE_LOCK_WAIT_S=1 "$S/git-hygiene-sync.sh" 2>&1)"   # no HYGIENE_REPOS → discovery
check "discovery found and fast-forwarded A" '[ -f "$W/A/u.md" ] && printf "%s" "$out" | grep -q "ff A"'

echo "== T9 foreign staging stays staged and out of the commit (--only)"
world t9
echo foreign > "$W/A/f.md"; echo "foreign edit" > "$W/A/a.md"; git -C "$W/A" add f.md a.md   # a new AND a modified file
echo mine > "$W/A/m.md"
"$S/git-safe-commit-push.sh" "$W/A" "mine only" m.md >/dev/null 2>&1; rc=$?
check "rc 0, own file pushed" '[ $rc -eq 0 ] && [ "$(on_origin m.md)" = mine ]'
check "foreign file NOT on origin" '[ -z "$(on_origin f.md)" ]'
check "foreign files still staged locally (incl. the modified one)" '[ "$(git -C "$W/A" diff --cached --name-only | tr "\n" " ")" = "a.md f.md " ]'

echo "== T10 another session's change cannot be restored after the rebase: own exit code"
world t10
echo "B v2" > "$W/B/a.md"; "$S/git-safe-commit-push.sh" "$W/B" "B a" a.md >/dev/null 2>&1
echo "A wip on a" > "$W/A/a.md"        # uncommitted work of another session in clone A
echo k > "$W/A/k.md"
"$S/git-safe-commit-push.sh" "$W/A" "add k" k.md > "$T/out-t10" 2>&1; rc=$?
check "rc 6 (pushed, stash left behind)" '[ $rc -eq 6 ] && [ "$(on_origin k.md)" = k ]'
check "the other session's change is in the stash, not lost" 'git -C "$W/A" stash show -p | grep -q "A wip on a"'

echo "== T11 log-append on a feature branch goes to main via a throwaway worktree"
world t11
git -C "$W/A" checkout -q -b feature
WIKI_DIR="$W/A" "$S/log-append.sh" "## e5 — off-branch" > "$T/out-t11" 2>&1; rc=$?
check "rc 0, entry on origin/main" '[ $rc -eq 0 ] && on_origin log.md | grep -q "^## e5"'
check "clone stays on feature, untouched" '[ "$(git -C "$W/A" symbolic-ref --short HEAD)" = feature ] && [ -z "$(git -C "$W/A" status --porcelain)" ] && [ "$(git -C "$W/A" worktree list | wc -l | tr -d " ")" = 1 ]'
LOG_APPEND_OFF_BRANCH=refuse WIKI_DIR="$W/A" "$S/log-append.sh" "## e6 — refused" >/dev/null 2>&1; rc=$?
check "refuse mode: rc 7, entry spooled, not on origin" '[ $rc -eq 7 ] && grep -rq "e6 — refused" "$HOME/.local/state/log-spool" && ! on_origin log.md | grep -q "e6"'

echo "== T12 a commit left local by a failed push is pushed by the next run"
world t12
echo r > "$W/A/r.md"
GSCP_REMOTE=nowhere GSCP_MAXTRIES=1 "$S/git-safe-commit-push.sh" "$W/A" "add r" r.md >/dev/null 2>&1; rc1=$?
"$S/git-safe-commit-push.sh" "$W/A" "add r" r.md > "$T/out-t12" 2>&1; rc2=$?
check "first run not pushed (rc 5), second run pushes the local commit (rc 0)" '[ $rc1 -eq 5 ] && [ $rc2 -eq 0 ] && [ "$(on_origin r.md)" = r ]'

echo "== T13 dry-run leaves the real index exactly as it was"
world t13
echo staged > "$W/A/a.md"; git -C "$W/A" add a.md; echo worktree > "$W/A/a.md"
idx_before="$(git -C "$W/A" ls-files -s a.md)"
GSCP_DRYRUN=1 "$S/git-safe-commit-push.sh" "$W/A" "dry" a.md >/dev/null 2>&1; rc=$?
check "rc 0, staged blob unchanged" '[ $rc -eq 0 ] && [ "$(git -C "$W/A" ls-files -s a.md)" = "$idx_before" ]'

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
