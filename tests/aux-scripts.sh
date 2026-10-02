#!/bin/bash
# =============================================================================
# aux-scripts.sh — throwaway-repo tests for backup-own-memories.sh and
# system-health.sh (the lock/push mechanics are covered by harness.sh).
# No network: a bare repo under mktemp is `origin`; HOME is inside the test tree.
# Run: /bin/bash tests/aux-scripts.sh      Exit 0 = all passed.
# =============================================================================
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/aux-XXXXXX")" || { echo "cannot create temp dir — aborting, nothing tested" >&2; exit 1; }
export XDG_STATE_HOME="$T/state"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_IDENT="12345+you@users.noreply.github.com"
export GIT_AUTHOR_NAME=test GIT_COMMITTER_NAME=test GIT_AUTHOR_EMAIL="$GIT_IDENT" GIT_COMMITTER_EMAIL="$GIT_IDENT"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
rec()  { sed -n "s/^$2=//p" "$1" | head -1; }

# ---- fixture: bare origin + node-memory clone + two profile dirs -------------
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$HOME/node-memory" 2>/dev/null
( cd "$HOME/node-memory" && git checkout -q -b main && echo "# node-memory" > README.md && git add README.md \
  && git -c user.email="$GIT_IDENT" -c user.name=test commit -q -m init && git push -q -u origin main )
mkdir -p "$HOME/.claude/projects/proj-a/memory" "$HOME/.claude-worker/projects/proj-b/memory"
echo "fact a" > "$HOME/.claude/projects/proj-a/memory/a.md"
echo "fact b" > "$HOME/.claude-worker/projects/proj-b/memory/b.md"
BK="$HERE/scripts/backup-own-memories.sh"
REC="$HOME/.records/backup-own-memories-worker-a.record"

echo "== B1 backup: both profiles mirrored, pushed, record ok"
"$BK" worker-a >/dev/null 2>&1; rc=$?
check "rc 0" "[ $rc -eq 0 ]"
check "record verdict ok" "[ \"\$(rec $REC verdict)\" = ok ]"
check "record carries max_age_s" "[ -n \"\$(rec $REC max_age_s)\" ]"
check "interactive profile on origin" "git -C $T/origin.git cat-file -e main:worker-a/memory/claude/proj-a/a.md 2>/dev/null"
check "worker profile on origin" "git -C $T/origin.git cat-file -e main:worker-a/memory/claude-worker/proj-b/b.md 2>/dev/null"

echo "== B2 backup: nothing changed → rc 0, no new commit"
before="$(git -C $T/origin.git rev-parse main)"
"$BK" worker-a >/dev/null 2>&1; rc=$?
check "rc 0" "[ $rc -eq 0 ]"
check "origin unchanged" "[ \"\$(git -C $T/origin.git rev-parse main)\" = $before ]"

echo "== B3 backup: sources exist but hold zero memory dirs → FAIL record, rc 3"
mkdir -p "$T/empty/projects"
MEMORY_SRCS="$T/empty/projects" "$BK" worker-a >/dev/null 2>&1; rc=$?
check "rc 3" "[ $rc -eq 3 ]"
check "record verdict fail with rc" "[ \"\$(rec $REC verdict)\" = fail ] && [ \"\$(rec $REC rc)\" = 3 ]"

echo "== B4 backup: no source dir at all → rc 3 (never an empty success)"
MEMORY_SRCS="$T/nope" "$BK" worker-a >/dev/null 2>&1; rc=$?
check "rc 3" "[ $rc -eq 3 ]"

echo "== B5 backup: foreign staged file in the clone stays out of the backup commit"
echo "foreign" > "$HOME/node-memory/foreign.md"; git -C "$HOME/node-memory" add foreign.md
echo "fact a2" > "$HOME/.claude/projects/proj-a/memory/a.md"
"$BK" worker-a >/dev/null 2>&1; rc=$?
check "rc 0" "[ $rc -eq 0 ]"
check "foreign file NOT on origin" "! git -C $T/origin.git cat-file -e main:foreign.md 2>/dev/null"
check "foreign file still staged" "git -C $HOME/node-memory diff --cached --name-only | grep -q foreign.md"

echo "== B6 backup: push fails → FAIL record; next run with NOTHING new still pushes the local commit"
mv "$T/origin.git" "$T/origin.away"
echo "fact a3" > "$HOME/.claude/projects/proj-a/memory/a.md"
GSCP_MAXTRIES=1 "$BK" worker-a >"$T/b6.out" 2>&1; rc=$?
[ "$rc" -eq 5 ] || { echo "  [debug] B6 first run rc=$rc"; sed "s/^/  [debug] /" "$T/b6.out"; }
check "rc 5 (not pushed), record fail" "[ $rc -eq 5 ] && [ \"\$(rec $REC verdict)\" = fail ]"
mv "$T/origin.away" "$T/origin.git"
"$BK" worker-a >/dev/null 2>&1; rc=$?
check "re-run without changes pushes the pending commit, record ok" "[ $rc -eq 0 ] && [ \"\$(rec $REC verdict)\" = ok ]"
check "a3 on origin" "[ \"\$(git -C $T/origin.git show main:worker-a/memory/claude/proj-a/a.md)\" = 'fact a3' ]"

echo "== B7 backup: an explicitly configured profile dir that is missing → rc 3, nothing silently skipped"
MEMORY_SRCS="$HOME/.claude/projects $T/vanished/projects" "$BK" worker-a >/dev/null 2>&1; rc=$?
check "rc 3 with one configured source missing" "[ $rc -eq 3 ] && [ \"\$(rec $REC verdict)\" = fail ]"

# ---- system-health ------------------------------------------------------------
SH="$HERE/scripts/system-health.sh"
mkdir -p "$HOME/Developer"; git clone -q "$T/origin.git" "$HOME/Developer/wiki" 2>/dev/null
OWN="$HOME/.records/system-health.record"
printf '{"status":"ok"}\n' > "$T/healthz.json"; export PROBE_URL="file://$T/healthz.json"   # no network: curl reads a file
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "== H1 health: no records, no workers → unchecked, rc 2, own record written"
WORKERS="" "$SH" >/dev/null 2>&1; rc=$?
check "rc 2 (unchecked only)" "[ $rc -eq 2 ]"
check "own record verdict unchecked" "[ \"\$(rec $OWN verdict)\" = unchecked ]"
check "own record has expiry" "[ -n \"\$(rec $OWN max_age_s)\" ]"

echo "== H2 health: fresh ok record + reachable probe stub → ok counted"
printf 'verdict=ok\nrc=0\nts=%s\nmax_age_s=93600\nlast=x\n' "$now" > "$HOME/.records/backup-fleet-memories.record"
WORKERS="" "$SH" >/dev/null 2>&1
check "hub pull-backstop reported ok" "grep -q 'OK        hub pull-backstop: ok' $HOME/.records/system-health.log"

echo "== H3 health: expired record → unchecked (not green, not red)"
printf 'verdict=ok\nrc=0\nts=2000-01-01T00:00:00Z\nmax_age_s=60\nlast=x\n' > "$HOME/.records/backup-fleet-memories.record"
WORKERS="" "$SH" >/dev/null 2>&1
check "expired reads as unchecked" "grep -q 'UNCHECKED hub pull-backstop: record expired' $HOME/.records/system-health.log"

echo "== H4 health: fail record → fail, rc 1"
printf 'verdict=fail\nrc=7\nts=%s\nmax_age_s=93600\nlast=rsync died\n' "$now" > "$HOME/.records/backup-fleet-memories.record"
WORKERS="" "$SH" >/dev/null 2>&1; rc=$?
check "rc 1" "[ $rc -eq 1 ]"
check "fail line carries rc and last line" "grep -q 'FAIL      hub pull-backstop: last run FAILED rc=7 (rsync died)' $HOME/.records/system-health.log"

echo "== H6 health: an unhealthy /healthz body is NOT ok; a record without max_age_s is unchecked, not green"
printf '{"status":"fail"}\n' > "$T/healthz-bad.json"
PROBE_URL="file://$T/healthz-bad.json" WORKERS="" "$SH" >/dev/null 2>&1
check "status:fail counted as FAIL" "grep -q 'FAIL      local service' $HOME/.records/system-health.log"
printf 'verdict=ok\nrc=0\nts=2000-01-01T00:00:00Z\nlast=x\n' > "$HOME/.records/backup-fleet-memories.record"
WORKERS="" "$SH" >/dev/null 2>&1
check "missing max_age_s → unchecked" "grep -q 'UNCHECKED hub pull-backstop: record has no valid max_age_s' $HOME/.records/system-health.log"

echo "== H5 health: notify on state change only"
NOTE="$T/notify.sh"; printf '#!/bin/bash\necho CALL >> "%s/notified"\n' "$T" > "$NOTE"; chmod +x "$NOTE"
rm -f "$T/notified" "$HOME/.records/system-health.last-findings"
NOTIFY_HELPER="$NOTE" WORKERS="" "$SH" >/dev/null 2>&1
NOTIFY_HELPER="$NOTE" WORKERS="" "$SH" >/dev/null 2>&1
n="$(wc -l < "$T/notified" 2>/dev/null | tr -d ' ')"
check "same findings twice → exactly one notification" "[ \"${n:-0}\" = 1 ]"
printf 'verdict=ok\nrc=0\nts=%s\nmax_age_s=93600\nlast=x\n' "$now" > "$HOME/.records/backup-fleet-memories.record"
NOTIFY_HELPER="$NOTE" WORKERS="" "$SH" >/dev/null 2>&1
n="$(wc -l < "$T/notified" | tr -d ' ')"
check "state change → second notification" "[ \"$n\" = 2 ]"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
