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
  unset STUB_DF_USE STUB_DF_USE2 STUB_PS SAB_API_KEY SONARR_API_KEY WATCH_CONTAINERS CERT_HOST CERT_CONFIG_DIR SCLIENT_RC CHECKEND_RC
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
echo "### A. static: stall-check wiring"
# These two were once dead code (defined, never called). They are wired into the
# ROLE=media branch of the main loop; keep them that way. Each must have exactly
# one call site, it must be inside the `[ "$ROLE" = media ]` block, and it must
# be a bare call -- not a comment or a string.
new_case static
for fn in check_qbit check_sab; do
  # Call sites: the bare name appearing on its own as a statement.
  sites=$(grep -nE "^\s*$fn\s*$" "$SCRIPT" | wc -l)
  n=$(printf '%s' "$sites" | tr -d ' ')
  assert "$fn has exactly one call site (found $n)" "$([ "$n" = 1 ] && echo 0 || echo 1)"

  # It must sit between the media-role guard and its closing `fi`.
  line=$(grep -nE "^\s*$fn\s*$" "$SCRIPT" | head -1 | cut -d: -f1)
  if [ -n "$line" ]; then
    guard=$(awk -v stop="$line" \
      '/\[ "\$ROLE" = media \]/{g=NR} NR==stop{print (g ? 1 : 0); exit}' "$SCRIPT")
    assert "$fn call site is inside the ROLE=media branch" "$([ "${guard:-0}" = 1 ] && echo 0 || echo 1)"
  else
    bad "$fn call site is inside the ROLE=media branch (no call site found)"
  fi
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
echo "### J. TLS certificate discovery, verification, and state"
new_case tls-discovery
CERT_CONFIG_DIR="$WORK/tls-config-discovery"; mkdir -p "$CERT_CONFIG_DIR"
cat > "$CERT_CONFIG_DIR/one.conf" <<'EOF'
server {
  listen 443 ssl;
  server_name tls-one.example;
}
EOF
cat > "$CERT_CONFIG_DIR/http.conf" <<'EOF'
server {
  listen 80;
  server_name tls-skipped.example;
}
EOF
cat > "$CERT_CONFIG_DIR/multiple.conf" <<'EOF'
server {
  listen 443 ssl;
  server_name tls-two.example tls-three.example _ ~ignored.example;
}
EOF
export CERT_CONFIG_DIR
run_body 'check_certificates'
assert "443 single host is silently recorded ok" "$([ "$(cat "$STATE_DIR/certificate.tls-one.example.status")" = ok ] && [ "$(sends)" = 0 ] && echo 0 || echo 1)"
assert "port-80 host is skipped" "$([ ! -f "$STATE_DIR/certificate.tls-skipped.example.status" ] && echo 0 || echo 1)"
assert "multiple valid server_names are checked" "$([ "$(cat "$STATE_DIR/certificate.tls-two.example.status")" = ok ] && [ "$(cat "$STATE_DIR/certificate.tls-three.example.status")" = ok ] && echo 0 || echo 1)"
assert "underscore and regex server_names are filtered" "$([ ! -f "$STATE_DIR/certificate._.status" ] && [ ! -f "$STATE_DIR/certificate.ignored.example.status" ] && echo 0 || echo 1)"

new_case tls-failure
CERT_CONFIG_DIR="$WORK/tls-config-failure"; mkdir -p "$CERT_CONFIG_DIR"
printf 'server {\n listen 443 ssl;\n server_name broken.example;\n}\n' > "$CERT_CONFIG_DIR/site.conf"
export CERT_CONFIG_DIR SCLIENT_RC=1
run_body 'check_certificates'
assert "verify failure writes failed status and alerts once" "$([ "$(cat "$STATE_DIR/certificate.broken.example.status")" = failed ] && [ "$(sends)" = 1 ] && sent 'verification failed for broken.example' && echo 0 || echo 1)"
before=$(sends); run_body 'check_certificates'
assert "repeated failure does not duplicate alert" "$([ "$(sends)" = "$before" ] && echo 0 || echo 1)"
unset SCLIENT_RC
run_body 'check_certificates'
assert "recovery writes ok and alerts once" "$([ "$(cat "$STATE_DIR/certificate.broken.example.status")" = ok ] && [ "$(sends)" = 2 ] && sent 'verifies successfully again' && echo 0 || echo 1)"
before=$(sends); run_body 'check_certificates'
assert "staying recovered does not duplicate alert" "$([ "$(sends)" = "$before" ] && echo 0 || echo 1)"

new_case tls-expiry
CERT_CONFIG_DIR="$WORK/tls-config-expiry"; mkdir -p "$CERT_CONFIG_DIR"
printf 'server {\n listen 443 ssl;\n server_name expiring.example;\n}\n' > "$CERT_CONFIG_DIR/site.conf"
export CERT_CONFIG_DIR CHECKEND_RC=1
run_body 'check_certificates'
assert "expiry check writes warning and sends warning alert" "$([ "$(cat "$STATE_DIR/certificate.expiring.example.status")" = warning ] && [ "$(sends)" = 1 ] && sent 'expires within' && echo 0 || echo 1)"
before=$(sends); run_body 'check_certificates'
assert "repeat expiry warning does not duplicate alert" "$([ "$(sends)" = "$before" ] && echo 0 || echo 1)"

new_case tls-no-config
run_body 'check_certificates'
assert "unset config dir is silent no-op" "$([ "$(sends)" = 0 ] && [ -z "$(find "$STATE_DIR" -name 'certificate.*' -print)" ] && echo 0 || echo 1)"
CERT_CONFIG_DIR="$WORK/not-present"; export CERT_CONFIG_DIR
run_body 'check_certificates'
assert "missing config dir is silent no-op" "$([ "$(sends)" = 0 ] && [ -z "$(find "$STATE_DIR" -name 'certificate.*' -print)" ] && echo 0 || echo 1)"

# ===========================================================================
echo
echo "### K. TERM handling: prompt shutdown (timing-sensitive)"
# Regression guard for the `docker stop` latency fix.
#
# The defect: the signal trap killed the watch_events child but did not exit, so
# the main `while :` loop resumed and the container ignored TERM until Docker
# gave up and SIGKILLed it (measured ~10s, exit 137). The fix adds `exit 0` to
# the handler and runs the script under `exec` so the shell receiving TERM is
# the script itself.
#
# Unlike every other case here, this one cannot use the extracted lib: it needs
# a real long-lived process to signal. We run the real script with stub binaries
# on PATH so its polling loop is cheap, TERM it, and measure how long it takes
# to die.
#
# Timing budget: the loop sleeps POLL_INTERVAL=1, so a correct exit lands well
# under ~2s. The failing behaviour was bounded by Docker's 10s grace period. Any
# exit under TERM_DEADLINE is a pass; using a deadline far above the observed
# good case keeps this robust on loaded CI runners while still failing hard if
# the trap regresses to "ignore TERM".
new_case term
TERM_DEADLINE=5      # seconds; correct fix exits in <2s, regression runs to ~10s

# Minimal stubs for everything the script touches at startup. The real polling
# loop calls these; we do not care about their output here, only that the
# process stays alive until we signal it.
stub_bin="$WORK/term-bin"; mkdir -p "$stub_bin"
for b in docker df openssl; do
  printf '#!/bin/sh\nexit 0\n' > "$stub_bin/$b"; chmod +x "$stub_bin/$b"
done
printf '#!/bin/sh\nexit 0\n' > "$stub_bin/curl"; chmod +x "$stub_bin/curl"

# Run the production script's REAL main body (not the extracted lib) so the trap
# under test is the production trap. State goes to the case dir; ROLE=general
# keeps the loop short, and CERT_HOST unset keeps openssl out of the path.
(
  set -eu
  PATH="$stub_bin:$PATH"
  STATE_DIR="$STATE" ROLE=general POLL_INTERVAL=1 \
  TELEGRAM_BOT_TOKEN=stub-token TELEGRAM_CHAT_ID=stub-chat CERT_CONFIG_DIR= \
  exec sh "$SCRIPT"
) >"$WORK/term.out" 2>&1 &
child=$!

# Let it reach the main loop before signalling.
sleep 1
start=$(date +%s)
kill -TERM "$child" 2>/dev/null || true

# Poll for exit, bounded by the deadline.
exited=0
while [ $(( $(date +%s) - start )) -lt "$TERM_DEADLINE" ]; do
  if ! kill -0 "$child" 2>/dev/null; then exited=1; break; fi
  sleep 0.1
done
elapsed=$(( $(date +%s) - start ))

if [ "$exited" = 1 ]; then
  # Reap so we get the true exit status (rather than signalling a zombie).
  wait "$child" 2>/dev/null; rc=$?
  assert "script exits on TERM within ${TERM_DEADLINE}s (took ~${elapsed}s)" \
    "$([ "$elapsed" -lt "$TERM_DEADLINE" ] && echo 0 || echo 1)"
  assert "exit status is 0 (clean shutdown, not SIGKILL)" \
    "$([ "$rc" = 0 ] && echo 0 || echo 1)"
else
  kill -KILL "$child" 2>/dev/null || true
  bad "script exits on TERM within ${TERM_DEADLINE}s (still alive after ${elapsed}s -> trap ignored TERM)"
  bad "exit status is 0 (never exited)"
fi

# ===========================================================================
echo
printf '== total: \033[32m%s passed\033[0m, \033[31m%s failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0