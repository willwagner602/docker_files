#!/bin/sh
# Function-level test suite for scripts/health-notify.sh, against stubs.
#
# Run from anywhere:  sh scripts/tests/health-notify/tests.sh
# Or via the Makefile:  make test
#
# The real script's main body (reconcile_health; watch_events &; trap; while loop)
# runs unconditionally at the bottom, so it cannot be sourced directly. Instead
# we extract everything above the `reconcile_health` call -- the function
# definitions and the default-variable block -- into a lib file. No production
# code is modified for testability.
#
# Each case runs the extracted lib under `set -eu` in its own subshell, matching
# the production shell semantics (`set -eu` is on line 2 of the script).
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
SCRIPT="$REPO/scripts/health-notify.sh"
PATH="$HERE/bin:$PATH"
export PATH
# The stub binaries must be executable. The suite deliberately does not chmod
# them: a test run must not mutate the working tree (git records file modes, so
# a silent chmod would also show up as a spurious diff). Fail loudly instead, so
# a mis-checked-out or mode-stripped tree reports the fix rather than failing
# later with a confusing "Permission denied".
for _stub in "$HERE"/bin/*; do
  if [ ! -x "$_stub" ]; then
    echo "FATAL: stub is not executable: $_stub" >&2
    echo "       fix with: chmod +x $HERE/bin/*" >&2
    exit 1
  fi
done
unset _stub

# All build scratch (extracted lib, per-case state dirs, curl logs) goes to a
# temp work dir so running the suite never dirties the tracked source tree.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/hn-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
LIB="$WORK/lib-extracted.sh"

# --- extract the function library -------------------------------------------
awk '/^reconcile_health$/{exit} {print}' "$SCRIPT" |
  grep -v '^#!' | grep -v '^set -eu$' > "$LIB"
if ! grep -q '^check_disk()' "$LIB"; then
  echo "FATAL: extraction failed (check_disk missing from $LIB)"; exit 1
fi
if grep -q '^reconcile_health$' "$LIB"; then
  echo "FATAL: extraction ran past the main body"; exit 1
fi

PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
assert() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1"; fi; }
sends()  { n=$(grep -c '^SEND|' "$CURL_LOG" 2>/dev/null); [ -n "$n" ] || n=0; printf '%s' "$n"; }
sent()   { grep -q "^SEND|.*$1" "$CURL_LOG" 2>/dev/null; }
show()   { sed 's/^/        | /' "$CURL_LOG" 2>/dev/null; }

# --- case scaffolding -------------------------------------------------------
# new_case <label>: fresh state dir + curl log; resets stub env.
new_case() {
  LABEL=$1
  STATE="$WORK/t10-state-$LABEL"; rm -rf "$STATE"; mkdir -p "$STATE"
  CURL_LOG="$WORK/t10-curl-$LABEL.log"; : > "$CURL_LOG"
  export CURL_LOG STATE_DIR="$STATE"
  export TELEGRAM_BOT_TOKEN=stub-token TELEGRAM_CHAT_ID=stub-chat
  unset STUB_HTTP_BODY STUB_HTTP_FAIL STUB_FAIL_MATCH STUB_EVENTS STUB_EVENTS_BLOCK STUB_PS
  unset STUB_DF_USE STUB_DF_USE2 STUB_PS SAB_API_KEY SONARR_API_KEY WATCH_CONTAINERS CERT_HOST
  unset SAB_API_KEY 2>/dev/null || true
  export POLL_INTERVAL=1 STALL_SECONDS=3600 DISK_FREE_THRESHOLD=25
  echo "== $LABEL"
}

# run <snippet>: execute the snippet with the lib sourced, under set -eu.
run_body() {
  ( set -eu; . "$LIB"; eval "$1" )
  RC=$?
}

# ===========================================================================
echo "### A. static: dead code inventory"
new_case static
for fn in check_qbit check_sab; do
  sites=$(grep -nE "(^|[^a-z_])$fn([^a-z_]|$)" "$SCRIPT" | grep -vE "^[0-9]+:$fn\(\)" | grep -vE "^\s*#" | wc -l)
  n=$(printf '%s' "$sites" | tr -d ' ')
  assert "$fn has NO call site outside its own definition (found $n)" "$([ "$n" = 0 ] && echo 0 || echo 1)"
done

# ===========================================================================
echo
echo "### B. check_disk (df stub; threshold 25% free)"
new_case disk
STUB_DF_USE=95 STUB_DF_USE2=95   # 95% used -> 5% free, below the 25 threshold
export STUB_DF_USE STUB_DF_USE2
run_body 'check_disk'
assert "low disk (95% used -> 5% free) alerts" "$(sent 'Disk space is low on /data' && echo 0 || echo 1)"
assert "state disk._dev_sda1=low written" "$([ "$(cat "$STATE_DIR/disk._dev_sda1" 2>/dev/null)" = low ] && echo 0 || echo 1)"
before=$(sends)
run_body 'check_disk'
assert "repeat low does NOT re-alert (no state change)" "$([ "$(sends)" = "$before" ] && echo 0 || echo 1)"
STUB_DF_USE=30 STUB_DF_USE2=30
export STUB_DF_USE STUB_DF_USE2
run_body 'check_disk'
assert "recovery to 70% free alerts once" "$(sent 'Disk space recovered on /data' && echo 0 || echo 1)"
before=$(sends)
run_body 'check_disk'
assert "staying recovered does NOT re-alert" "$([ "$(sends)" = "$before" ] && echo 0 || echo 1)"

# ===========================================================================
echo
echo "### C. check_http (3-failure threshold + recovery)"
new_case http
export STUB_FAIL_MATCH="plex"
run_body 'check_http Plex http://plex:32400/identity'
assert "1st failure: silent (below threshold)" "$([ "$(sends)" = 0 ] && echo 0 || echo 1)"
run_body 'check_http Plex http://plex:32400/identity'
assert "2nd failure: silent" "$([ "$(sends)" = 0 ] && echo 0 || echo 1)"
run_body 'check_http Plex http://plex:32400/identity'
assert "3rd failure: alerts 'not responding after 3 checks'" "$(sent 'Plex is not responding after 3 checks' && echo 0 || echo 1)"
assert "status file flipped to down" "$([ "$(cat "$STATE_DIR/http.Plex.status")" = down ] && echo 0 || echo 1)"
before=$(sends)
run_body 'check_http Plex http://plex:32400/identity'
assert "4th failure: no duplicate alert (already down)" "$([ "$(sends)" = "$before" ] && echo 0 || echo 1)"
unset STUB_FAIL_MATCH
run_body 'check_http Plex http://plex:32400/identity'
assert "recovery alerts 'responding again'" "$(sent 'Plex is responding again' && echo 0 || echo 1)"
assert "failure counter reset to 0" "$([ "$(cat "$STATE_DIR/http.Plex.failures")" = 0 ] && echo 0 || echo 1)"
before=$(sends)
run_body 'check_http Plex http://plex:32400/identity'
assert "staying up does NOT re-alert" "$([ "$(sends)" = "$before" ] && echo 0 || echo 1)"

# ===========================================================================
echo
echo "### D. check_arr (baseline, then new-failure detection)"
new_case arr
BODY1='{"records":[{"id":100,"eventType":"downloadFolderImported"}]}'
BODY2='{"records":[{"id":101,"eventType":"downloadFailed","series":{"title":"Show X"},"data":{"message":"no peers"}},{"id":102,"eventType":"grabbed","series":{"title":"Show Y"}}]}'
STUB_HTTP_BODY="$BODY1"; export STUB_HTTP_BODY
run_body 'check_arr Sonarr http://sonarr:8989 key123 arr.sonarr.last'
assert "first run is baseline only (silent)" "$([ "$(sends)" = 0 ] && echo 0 || echo 1)"
assert "baseline id 100 recorded" "$([ "$(cat "$STATE_DIR/arr.sonarr.last")" = 100 ] && echo 0 || echo 1)"
STUB_HTTP_BODY="$BODY2"; export STUB_HTTP_BODY
run_body 'check_arr Sonarr http://sonarr:8989 key123 arr.sonarr.last'
assert "new failure 101 alerts" "$(sent 'Show X' && echo 0 || echo 1)"
assert "non-failure event 102 (grabbed) is NOT alerted" "$(sent 'Show Y' && echo 1 || echo 0)"
assert "exactly one alert sent" "$([ "$(sends)" = 1 ] && echo 0 || echo 1)"
assert "watermark advanced to 102" "$([ "$(cat "$STATE_DIR/arr.sonarr.last")" = 102 ] && echo 0 || echo 1)"
before=$(sends)
run_body 'check_arr Sonarr http://sonarr:8989 key123 arr.sonarr.last'
assert "re-poll with unchanged history does not re-alert" "$([ "$(sends)" = "$before" ] && echo 0 || echo 1)"
STUB_HTTP_BODY=""; export STUB_HTTP_BODY
run_body 'check_arr Sonarr http://sonarr:8989 "" arr.sonarr.last'
assert "empty API key short-circuits (no request, no alert)" "$([ "$(sends)" = "$before" ] && echo 0 || echo 1)"

# ===========================================================================
echo
echo "### E. check_sab stall alert (STALL_SECONDS=0)"
new_case sab
export SAB_API_KEY=key123 STALL_SECONDS=0
export STUB_HTTP_BODY='{"queue":{"slots":[{"nzo_id":"nzo_1","filename":"Big.File","mbleft":"500.00","status":"Downloading"}]}}'
run_body 'check_sab'
assert "1st sighting: records signature, silent" "$([ "$(sends)" = 0 ] && echo 0 || echo 1)"
run_body 'check_sab'
assert "no progress for >= STALL_SECONDS: stalls alert" "$(sent 'SABnzbd has had no queue progress' && echo 0 || echo 1)"
assert "alerted flag set" "$([ "$(cat "$STATE_DIR/sab.alerted")" = 1 ] && echo 0 || echo 1)"
before=$(sends)
run_body 'check_sab'
assert "still stalled: no duplicate alert" "$([ "$(sends)" = "$before" ] && echo 0 || echo 1)"
export STUB_HTTP_BODY='{"queue":{"slots":[]}}'
run_body 'check_sab'
assert "queue clears: 'no longer stalled' alert" "$(sent 'SABnzbd is no longer stalled' && echo 0 || echo 1)"

# ===========================================================================
echo
echo "### F. check_qbit stalled-torrent logic (via docker exec passthrough)"
new_case qbit
export STALL_SECONDS=3600
OLD=$(( $(date +%s) - 7200 ))
export STUB_HTTP_BODY="[{\"name\":\"Stuck.Torrent\",\"state\":\"stalledDL\",\"progress\":0.5,\"last_activity\":$OLD,\"added_on\":1}]"
run_body 'check_qbit'
assert "stalled torrent alerts" "$(sent 'Stuck.Torrent' && echo 0 || echo 1)"
assert "fingerprint stored" "$([ -s "$STATE_DIR/qbit.fingerprint" ] && echo 0 || echo 1)"
before=$(sends)
run_body 'check_qbit'
assert "unchanged stalled set: no duplicate alert" "$([ "$(sends)" = "$before" ] && echo 0 || echo 1)"
export STUB_HTTP_BODY='[]'
run_body 'check_qbit'
assert "queue cleared: 'stalled queue cleared' alert" "$(sent 'stalled queue cleared' && echo 0 || echo 1)"

# ===========================================================================
echo
echo "### G. handle_events: oom / restart / die / start"
new_case ev-oom
export STUB_EVENTS='oom|web||'
run_body 'handle_events'
assert "oom -> OOM-killed alert" "$(sent 'web was OOM-killed' && echo 0 || echo 1)"

new_case ev-restart
export STUB_EVENTS='restart|web||'
run_body 'handle_events'
assert "restart -> restarted alert" "$(sent 'web restarted' && echo 0 || echo 1)"

new_case ev-die-start
export STUB_EVENTS='die|web|137|'
run_body 'handle_events'
assert "die -> stopped alert with exit code" "$(sent 'web stopped (exit=137' && echo 0 || echo 1)"
assert "down.web marker written" "$([ -f "$STATE_DIR/down.web" ] && echo 0 || echo 1)"
export STUB_EVENTS='start|web||'
run_body 'handle_events'
assert "start -> 'started again' alert" "$(sent 'web started again' && echo 0 || echo 1)"
assert "down.web marker cleared" "$([ ! -f "$STATE_DIR/down.web" ] && echo 0 || echo 1)"

new_case ev-start-nomarker
export STUB_EVENTS='start|web||'
run_body 'handle_events'
assert "start with no down marker stays silent (no start spam)" "$([ "$(sends)" = 0 ] && echo 0 || echo 1)"

new_case ev-watch-filter
export WATCH_CONTAINERS='web' STUB_EVENTS='die|db|1|'
run_body 'handle_events'
assert "die for unwatched container is ignored" "$([ "$(sends)" = 0 ] && echo 0 || echo 1)"

new_case ev-health
export STUB_EVENTS='health_status: unhealthy|db||'
run_body 'handle_events'
assert "health_status unhealthy -> alert with detail" "$(sent 'db is unhealthy' && echo 0 || echo 1)"
export STUB_EVENTS='health_status: healthy|db||'
run_body 'handle_events'
assert "health_status healthy -> 'healthy again'" "$(sent 'db is healthy again' && echo 0 || echo 1)"

# ===========================================================================
echo
echo "### H. reconcile_health (startup sweep of already-unhealthy)"
new_case reconcile
export STUB_PS='db'
run_body 'reconcile_health'
assert "already-unhealthy container alerts at startup" "$(sent 'db is unhealthy' && echo 0 || echo 1)"
assert "health.db=unhealthy recorded" "$([ "$(cat "$STATE_DIR/health.db")" = unhealthy ] && echo 0 || echo 1)"
before=$(sends)
run_body 'reconcile_health'
assert "second sweep does NOT re-alert" "$([ "$(sends)" = "$before" ] && echo 0 || echo 1)"

new_case reconcile-stopped
export STUB_PS=''
run_body 'reconcile_health'
assert "no running containers -> silent" "$([ "$(sends)" = 0 ] && echo 0 || echo 1)"

# ===========================================================================
echo
echo "### I. check_unpackerr (default path unmounted -> no-op)"
new_case unpackerr
run_body 'check_unpackerr'
assert "missing log file is a silent no-op" "$([ "$(sends)" = 0 ] && echo 0 || echo 1)"
assert "no fingerprint written when file absent" "$([ ! -f "$STATE_DIR/unpackerr.fingerprint" ] && echo 0 || echo 1)"

# ===========================================================================
echo
printf '== total: \033[32m%s passed\033[0m, \033[31m%s failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0