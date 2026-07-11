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
# The hub's SSH probes here are the allowed exception to "nodes never talk to
# each other": read-only status reads, never state transfer (that stays git).
#
# Patterns demonstrated:
#   A. scheduled-job freshness via heartbeat-file age (not "is the PID alive")
#   B. endpoint probe for services (alive-but-wedged detection)
#   C. cross-node checkout depth vs origin (stale-read detection)
#   D. remote heartbeat content check ("ok" vs "FAIL" in the file)
# Heartbeats live under ~/.heartbeats (persistent) — NOT /tmp, which is wiped
# on reboot and produces false-stale alarms. bash 3.2-safe (macOS).
# =============================================================================
set -o pipefail

NOTIFY="${NOTIFY_HELPER:-$HOME/bin/notify}"
WIKI="$HOME/Developer/wiki"
LOG="$HOME/.heartbeats/system-health.log"
mkdir -p "$HOME/.heartbeats"
TS="$(date '+%Y-%m-%d %H:%M:%S')"
NOW="$(date +%s)"
STALE=93600   # 26h — generous vs daily cadences

PASS=(); FAIL=()

log_age() {  # seconds since file mtime, or huge if missing
  local f="$1"
  if [ -f "$f" ]; then echo $(( NOW - $(stat -f %m "$f" 2>/dev/null || echo 0) )); else echo 999999; fi
}

# ---- A. local scheduled job fresh? (heartbeat age, not PID) ------------------
HBAGE="$(log_age "$HOME/.heartbeats/backup-fleet-memories.done")"
if [ "$HBAGE" -lt "$STALE" ]; then
  PASS+=("hub pull-backstop: fresh ($((HBAGE/3600))h)")
else
  FAIL+=("hub pull-backstop: heartbeat stale/missing ($((HBAGE/3600))h) — job dead or never ran")
fi

# ---- B. service endpoint probe (not PID!) ------------------------------------
if curl -s --max-time 8 http://127.0.0.1:8090/health 2>/dev/null | grep -q '"status"'; then
  PASS+=("search-index API: reachable")
else
  FAIL+=("search-index API: unreachable — daemon/tunnel down (process may still be 'running')")
fi

# ---- C. are the workers' checkouts fresh vs ORIGIN? --------------------------
git -C "$WIKI" fetch -q origin 2>/dev/null || true
ORIGIN_HEAD="$(git -C "$WIKI" rev-parse origin/HEAD 2>/dev/null || git -C "$WIKI" rev-parse origin/main 2>/dev/null)"
for nd in "worker-a:/Users/worker/Developer/wiki" "worker-b:/Users/worker/Developer/wiki"; do
  host="${nd%%:*}"; path="${nd#*:}"
  NH="$(ssh -o ConnectTimeout=8 -o BatchMode=yes "$host" "git -C '$path' rev-parse HEAD 2>/dev/null" 2>/dev/null)"
  if [ -n "$NH" ] && [ -n "$ORIGIN_HEAD" ]; then
    if NB="$(git -C "$WIKI" rev-list --count "${NH}..${ORIGIN_HEAD}" 2>/dev/null)"; then
      if [ "$NB" -le 5 ]; then
        PASS+=("$host: wiki current ($NB behind origin)")
      else
        FAIL+=("$host: wiki $NB BEHIND origin — pull chain stalled")
      fi
    else
      # hash unknown to hub even after fetch → worker is AHEAD or diverged
      FAIL+=("$host: wiki HEAD unknown to origin — worker has unpushed work or diverged")
    fi
  else
    FAIL+=("$host: cannot read wiki HEAD (node down or clone missing)")
  fi
done

# ---- D. worker memory self-push heartbeats (content + age) -------------------
for nd in worker-a worker-b; do
  RHB="/Users/worker/.heartbeats/backup-own-memories-$nd.done"
  HBMT="$(ssh -o ConnectTimeout=8 -o BatchMode=yes "$nd" "stat -f %m '$RHB' 2>/dev/null" 2>/dev/null || echo 0)"
  if [ "${HBMT:-0}" -gt 0 ]; then
    HBAGE=$(( NOW - HBMT ))
    HBTXT="$(ssh -o ConnectTimeout=8 -o BatchMode=yes "$nd" "cat '$RHB' 2>/dev/null" 2>/dev/null)"
    case "$HBTXT" in
      *ok*) if [ "$HBAGE" -lt "$STALE" ]; then PASS+=("self-push $nd: ok ($((HBAGE/3600))h)"); else FAIL+=("self-push $nd: stale ($((HBAGE/3600))h) — cron dead?"); fi ;;
      *)    FAIL+=("self-push $nd: last run FAILED ($HBTXT)") ;;
    esac
  else
    FAIL+=("self-push $nd: no heartbeat readable (node down or job never ran)")
  fi
done

# ---- report -------------------------------------------------------------------
TOTAL=$(( ${#PASS[@]} + ${#FAIL[@]} ))
{
  echo "===== $TS system-health ($(( TOTAL - ${#FAIL[@]} ))/$TOTAL green) ====="
  [ ${#PASS[@]} -gt 0 ] && printf '  PASS %s\n' "${PASS[@]}"
  [ ${#FAIL[@]} -gt 0 ] && printf '  FAIL %s\n' "${FAIL[@]}"
} >> "$LOG"

if [ ${#FAIL[@]} -gt 0 ]; then
  MSG="$(printf '❌ %s\n' "${FAIL[@]}")"
  if [ -x "$NOTIFY" ]; then
    "$NOTIFY" -t "🩺 system-health: ${#FAIL[@]}/${TOTAL} RED" "$MSG"
  else
    echo "🩺 system-health ${#FAIL[@]}/${TOTAL} RED: $MSG"   # cron mails stdout
  fi
  exit 1
fi
exit 0
