#!/bin/bash
# =============================================================================
# system-health.sh — daily aggregator with THREE states: ok / fail / unchecked.
#
# Checks the knowledge stack IN CONCERT — closing the gap where a single
# component fails silently (dead cron, stale backup, dropped tunnel, checkout
# drifting behind origin, a headless agent profile that logged itself out).
#
# What changed from v1, and why (every item was a measured wrong green or red):
#  - a check that could not run is UNCHECKED, never green and never red:
#    node unreachable, fetch failed, record missing, probe tool absent
#  - every job is read through its RECORD (verdict + expiry), not an mtime guess;
#    per-job expiry travels in the record (max_age_s) — no threshold table here
#  - the depth check FETCHES FIRST; a failed fetch makes it unchecked (v1 did
#    `fetch || true` and compared against a stale tracking ref)
#  - one SSH call per remote record (mtime and content from the same file)
#  - this script writes ITS OWN expiring record, so another node can read it;
#    a local log line is not a heartbeat for anyone else
#  - sub-check exit codes propagate: exit 1 on any fail, 2 on unchecked-only
#  - notification on STATE CHANGE only (hash over finding classes, never run
#    counters); standing reds are listed in the daily record for a summary job
#
# This is a SKELETON with the check patterns that matter; add your own checks.
# Run daily on the hub AND a smaller copy on an always-on worker (docs/06). SSH
# probes are the allowed exception to "nodes never talk": read-only, no state.
# Records live under ~/.records (persistent) — NOT /tmp. bash 3.2-safe (macOS).
#
# Env: NOTIFY_HELPER · WIKI (default ~/Developer/wiki) · WORKERS "host:path host:path" · PROBE_URL (a /healthz)
#      AUTH_PROBE — newline-separated "host:command" records (command may contain spaces)
#      REMOTE_RECORD_DIR (default ~/.records on the worker) · AUTH_PROBE "host:cmd"
#      HEALTH_MAX_AGE_S (expiry of THIS script's record, default 93600 = 26 h)
# =============================================================================
set -o pipefail

NOTIFY="${NOTIFY_HELPER:-$HOME/bin/notify}"
WIKI="${WIKI:-$HOME/Developer/wiki}"
RECDIR="$HOME/.records"; mkdir -p "$RECDIR"
LOG="$RECDIR/system-health.log"
OWN="$RECDIR/system-health.record"
STATE="$RECDIR/system-health.last-findings"
MAX_AGE="${HEALTH_MAX_AGE_S:-93600}"
WORKERS="${WORKERS-worker-a:/Users/worker/Developer/wiki worker-b:/Users/worker/Developer/wiki}"   # WORKERS="" = none
REMOTE_RECORD_DIR="${REMOTE_RECORD_DIR:-/Users/worker/.records}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW="$(date +%s)"
SSH_OPTS="-o ConnectTimeout=8 -o BatchMode=yes"

OK=(); FAIL=(); UNCHECKED=()

# ---- record reader: prints "ok|fail|unchecked <detail>" for a record file's CONTENT -----
read_record() {  # $1 = record text (may be empty), $2 = label
  local txt="$1" label="$2" v rc ts age max
  [ -n "$txt" ] || { echo "unchecked $label: no record (job never ran, node down, or wiped after boot)"; return; }
  v="$(printf '%s\n' "$txt" | sed -n 's/^verdict=//p' | head -1)"
  rc="$(printf '%s\n' "$txt" | sed -n 's/^rc=//p' | head -1)"
  ts="$(printf '%s\n' "$txt" | sed -n 's/^ts=//p' | head -1)"
  max="$(printf '%s\n' "$txt" | sed -n 's/^max_age_s=//p' | head -1)"
  [ -n "$v" ] && [ -n "$ts" ] || { echo "unchecked $label: malformed record"; return; }
  case "$max" in ''|*[!0-9]*|0) echo "unchecked $label: record has no valid max_age_s — cannot judge freshness"; return ;; esac
  # ts is UTC ISO; parse portably (macOS date -j, GNU date -d)
  if ! epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null)"; then
    epoch="$(date -u -d "$ts" +%s 2>/dev/null)" || { echo "unchecked $label: unparsable ts $ts"; return; }
  fi
  age=$(( NOW - epoch ))
  if [ -n "$max" ] && [ "$age" -gt "$max" ]; then
    echo "unchecked $label: record expired ($((age/3600))h old, max $((max/3600))h) — job stopped running"; return
  fi
  case "$v" in
    ok)   echo "ok $label: ok ($((age/3600))h)";;
    fail) echo "fail $label: last run FAILED rc=$rc ($(printf '%s\n' "$txt" | sed -n 's/^last=//p' | head -1))";;
    *)    echo "unchecked $label: unknown verdict '$v'";;
  esac
}
classify() {  # takes "state detail" and files it
  case "$1" in
    ok\ *)        OK+=("${1#ok }");;
    fail\ *)      FAIL+=("${1#fail }");;
    unchecked\ *) UNCHECKED+=("${1#unchecked }");;
  esac
}

# ---- A. local scheduled job via its record -----------------------------------
classify "$(read_record "$(cat "$RECDIR/backup-fleet-memories.record" 2>/dev/null)" "hub pull-backstop")"

# ---- B. service endpoint probe (not PID!) ------------------------------------
if ! command -v curl >/dev/null 2>&1; then
  UNCHECKED+=("search-index API: curl missing — cannot probe")
elif curl -fsS --max-time 8 "${PROBE_URL:-http://127.0.0.1:PORT/healthz}" 2>/dev/null | grep -Eq '"(ok|status)" *: *(true|"ok")'; then
  # -f: an HTTP error is a failure, not a body to grep; and the body must SAY healthy — a bare
  # '"status"' key matched {"status":"fail"} just as happily (found by review)
  OK+=("local service: reachable")
else
  FAIL+=("local service: /healthz not answering (process may still be 'running')")
fi

# ---- C. workers' checkouts vs ORIGIN — fetch first, unchecked if the fetch fails ----
if git -C "$WIKI" fetch -q origin "+refs/heads/main:refs/remotes/origin/main" 2>/dev/null; then
  ORIGIN_HEAD="$(git -C "$WIKI" rev-parse refs/remotes/origin/main 2>/dev/null)"
else
  ORIGIN_HEAD=""
fi
for nd in $WORKERS; do
  host="${nd%%:*}"; path="${nd#*:}"
  if [ -z "$ORIGIN_HEAD" ]; then
    UNCHECKED+=("$host: wiki depth — hub could not fetch origin (network/auth); comparison skipped")
    continue
  fi
  NH="$(ssh $SSH_OPTS "$host" "git -C '$path' rev-parse HEAD 2>/dev/null" 2>/dev/null)"
  if [ -z "$NH" ]; then
    UNCHECKED+=("$host: wiki HEAD unreadable (node down, ssh denied, or clone missing)")
  elif NB="$(git -C "$WIKI" rev-list --count "${NH}..${ORIGIN_HEAD}" 2>/dev/null)"; then
    if [ "$NB" -le 5 ]; then OK+=("$host: wiki current ($NB behind origin)")
    else FAIL+=("$host: wiki $NB BEHIND origin — pull chain stalled"); fi
  else
    FAIL+=("$host: wiki HEAD unknown to origin — unpushed work or diverged")
  fi
done

# ---- D. worker self-push records: ONE ssh call per record (content carries ts + expiry) ----
for nd in $WORKERS; do
  host="${nd%%:*}"
  TXT="$(ssh $SSH_OPTS "$host" "cat '$REMOTE_RECORD_DIR/backup-own-memories-$host.record' 2>/dev/null" 2>/dev/null)"
  classify "$(read_record "$TXT" "self-push $host")"
done

# ---- E. headless agent profile still logged in? ---------------------------------------------
# AUTH_PROBE = one record per LINE, "host:command that exits 0 when logged in" — the command may
# contain spaces (word-splitting a space-separated list turned "cli auth status" into three hosts).
while IFS= read -r ap; do
  [ -n "$ap" ] || continue
  host="${ap%%:*}"; cmd="${ap#*:}"
  out="$(ssh $SSH_OPTS "$host" "$cmd" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then OK+=("$host: headless agent profile logged in")
  elif [ "$rc" -eq 255 ]; then UNCHECKED+=("$host: auth probe — ssh failed")
  else FAIL+=("$host: headless agent profile NOT logged in (rc=$rc: $(printf '%s' "$out" | tail -1))"); fi
done <<EOF_AP
${AUTH_PROBE:-}
EOF_AP

# ---- report + own record -----------------------------------------------------
TOTAL=$(( ${#OK[@]} + ${#FAIL[@]} + ${#UNCHECKED[@]} ))
{
  echo "===== $TS system-health (${#OK[@]} ok · ${#FAIL[@]} fail · ${#UNCHECKED[@]} unchecked / $TOTAL) ====="
  [ ${#OK[@]} -gt 0 ]        && printf '  OK        %s\n' "${OK[@]}"
  [ ${#FAIL[@]} -gt 0 ]      && printf '  FAIL      %s\n' "${FAIL[@]}"
  [ ${#UNCHECKED[@]} -gt 0 ] && printf '  UNCHECKED %s\n' "${UNCHECKED[@]}"
} >> "$LOG"

if   [ ${#FAIL[@]} -gt 0 ];      then VERDICT=fail; RC=1
elif [ ${#UNCHECKED[@]} -gt 0 ]; then VERDICT=unchecked; RC=2
else VERDICT=ok; RC=0; fi
printf 'verdict=%s\nrc=%s\nts=%s\nmax_age_s=%s\nok=%s\nfail=%s\nunchecked=%s\nlast=%s\n' \
  "$VERDICT" "$RC" "$TS" "$MAX_AGE" "${#OK[@]}" "${#FAIL[@]}" "${#UNCHECKED[@]}" \
  "$( { printf '%s; ' "${FAIL[@]}" "${UNCHECKED[@]}"; } 2>/dev/null | cut -c1-300)" > "$OWN.tmp" && mv -f "$OWN.tmp" "$OWN"

# ---- notify on STATE CHANGE only: hash the finding CLASSES (text before the colon), not counters ----
FINDINGS="$( { printf 'F %s\n' "${FAIL[@]}"; printf 'U %s\n' "${UNCHECKED[@]}"; } 2>/dev/null | sed 's/:.*//' | sort -u)"
HASH="$(printf '%s' "$FINDINGS" | shasum -a 256 2>/dev/null | cut -c1-16)"
PREV="$(cat "$STATE" 2>/dev/null)"
if [ "$HASH" != "$PREV" ]; then
  printf '%s' "$HASH" > "$STATE"
  if [ "$RC" -ne 0 ]; then
    MSG="$( { [ ${#FAIL[@]} -gt 0 ] && printf '❌ %s\n' "${FAIL[@]}"; [ ${#UNCHECKED[@]} -gt 0 ] && printf '❔ %s\n' "${UNCHECKED[@]}"; } 2>/dev/null)"
    if [ -x "$NOTIFY" ]; then "$NOTIFY" -t "🩺 system-health: ${#FAIL[@]} fail · ${#UNCHECKED[@]} unchecked" "$MSG"
    else echo "🩺 system-health ${#FAIL[@]} fail · ${#UNCHECKED[@]} unchecked:"; echo "$MSG"; fi
  else
    [ -n "$PREV" ] && [ -x "$NOTIFY" ] && "$NOTIFY" -t "🩺 system-health: back to all ok" "$TOTAL checks ok"
  fi
fi
exit "$RC"
