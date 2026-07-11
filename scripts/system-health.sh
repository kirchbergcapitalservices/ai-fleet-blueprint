#!/bin/bash
# =============================================================================
# system-health.sh — daily heartbeat aggregator (the dead-man's-switch).
#
# Checks the knowledge stack IN CONCERT and alerts on ANY red — closing the gap
# where a single component fails silently (dead cron, stale backup, dropped
# tunnel, checkout drifting behind origin). Notifies ONLY on failure.
#
# This is a SKELETON with the check patterns that matter; add your own checks.
# Run daily via launchd/cron on the hub — and remember: put a SECOND, smaller
# alerter on a worker so alarms also fire when the hub is off (see docs/06).
#
# Patterns demonstrated:
#   A. scheduled-job freshness via heartbeat-file age (not "is the PID alive")
#   B. endpoint probe for services (alive-but-wedged detection)
#   C. cross-node checkout depth vs origin (stale-read detection)
#   D. remote heartbeat content check ("ok" vs "FAIL" in the file)
# bash 3.2-safe (macOS). /tmp heartbeats die on reboot → expect false-stale then.
# =============================================================================
set -o pipefail

NOTIFY="${NOTIFY_HELPER:-$HOME/bin/notify}"
WIKI="$HOME/Developer/wiki"
LOG="/tmp/system-health.log"
TS="$(date '+%Y-%m-%d %H:%M:%S')"
NOW="$(date +%s)"
STALE=93600   # 26h — generous vs daily cadences

PASS=(); FAIL=()

log_age() {  # seconds since file mtime, or huge if missing
  local f="$1"
  if [ -f "$f" ]; then echo $(( NOW - $(stat -f %m "$f" 2>/dev/null || echo 0) )); else echo 999999; fi
}

# ---- A. own repo pushed? ---------------------------------------------------
UNPUSHED="$(git -C "$WIKI" rev-list --count '@{u}..HEAD' 2>/dev/null || echo '?')"
if [ "$UNPUSHED" = "0" ]; then PASS+=("wiki: synced"); else FAIL+=("wiki: ${UNPUSHED} unpushed commit(s)"); fi

# ---- B. service endpoint probe (not PID!) ----------------------------------
if curl -s --max-time 8 http://127.0.0.1:8090/health 2>/dev/null | grep -q '"status"'; then
  PASS+=("search-index API: reachable")
else
  FAIL+=("search-index API: unreachable — daemon/tunnel down (process may still be 'running')")
fi

# ---- C. are the workers' checkouts fresh? ----------------------------------
for nd in "worker-a:/Users/worker/Developer/wiki" "worker-b:/Users/worker/Developer/wiki"; do
  host="${nd%%:*}"; path="${nd#*:}"
  NH="$(ssh -o ConnectTimeout=8 -o BatchMode=yes "$host" "git -C '$path' rev-parse HEAD 2>/dev/null" 2>/dev/null)"
  if [ -n "$NH" ]; then
    NB="$(git -C "$WIKI" rev-list --count "${NH}..HEAD" 2>/dev/null || echo '?')"
    if [ "$NB" != "?" ] && [ "$NB" -le 5 ]; then
      PASS+=("$host: wiki current ($NB behind)")
    else
      FAIL+=("$host: wiki $NB BEHIND origin — pull chain stalled")
    fi
  else
    FAIL+=("$host: cannot read wiki HEAD (node down or clone missing)")
  fi
done

# ---- D. worker memory self-push heartbeats (content + age) ------------------
for nd in worker-a worker-b; do
  HBMT="$(ssh -o ConnectTimeout=8 -o BatchMode=yes "$nd" "stat -f %m /tmp/backup-own-memories-$nd.done 2>/dev/null" 2>/dev/null || echo 0)"
  if [ "${HBMT:-0}" -gt 0 ]; then
    HBAGE=$(( NOW - HBMT ))
    HBTXT="$(ssh -o ConnectTimeout=8 -o BatchMode=yes "$nd" "cat /tmp/backup-own-memories-$nd.done 2>/dev/null" 2>/dev/null)"
    case "$HBTXT" in
      *ok*) if [ "$HBAGE" -lt "$STALE" ]; then PASS+=("self-push $nd: ok ($((HBAGE/3600))h)"); else FAIL+=("self-push $nd: stale ($((HBAGE/3600))h) — cron dead?"); fi ;;
      *)    FAIL+=("self-push $nd: last run FAILED ($HBTXT)") ;;
    esac
  else
    FAIL+=("self-push $nd: no heartbeat readable (node down or job never ran)")
  fi
done

# ---- report -----------------------------------------------------------------
TOTAL=$(( ${#PASS[@]} + ${#FAIL[@]} ))
{
  echo "===== $TS system-health ($(( TOTAL - ${#FAIL[@]} ))/$TOTAL green) ====="
  [ ${#PASS[@]} -gt 0 ] && printf '  PASS %s\n' "${PASS[@]}"
  [ ${#FAIL[@]} -gt 0 ] && printf '  FAIL %s\n' "${FAIL[@]}"
} >> "$LOG"

if [ ${#FAIL[@]} -gt 0 ]; then
  [ -x "$NOTIFY" ] && "$NOTIFY" -t "🩺 system-health: ${#FAIL[@]}/${TOTAL} RED" "$(printf '❌ %s\n' "${FAIL[@]}")"
  exit 1
fi
exit 0
