#!/bin/sh
# Test the docker-ro wrapper's LOG FILTERING against a REAL docker daemon.
#
# This is the counterpart to scripts/tests/docker-ro/wrapper.sh, which stubs
# docker. The stub suite proves the allowlist boundary (which subcommands are
# reachable, which argument shapes are refused). It CANNOT prove:
#   * that the resolved docker binary path actually works on a real host
#     (a stub suite passed while the real path lookup was broken — see below),
#   * that `docker logs` really has no redaction flag,
#   * that the whitelist filter actually withholds secret-bearing lines from
#     real container log output.
#
# So this suite runs a throwaway container whose logs contain secret-shaped
# lines, and asserts the filtered output contains the diagnostics and does NOT
# contain the secrets.
#
#   sh scripts/tests/docker-ro/real-daemon.sh
#
# Requires: a working docker daemon and the alpine image (pulled on demand).
# Skips cleanly (exit 0) if no daemon is reachable, so it is safe to wire into
# `make check` on machines without docker.
#
# NOTE ON HISTORY: an earlier revision of the wrapper hardcoded
# DOCKER=/usr/bin/docker with an /usr/local/bin fallback. The stub suite passed
# anyway, because it rewrote those paths. On a host using the snap package
# (/snap/bin/docker) the wrapper failed at runtime with "docker CLI not found".
# That is the specific class of bug this real-daemon suite exists to catch.

set -u

repo_dir=$(cd "$(dirname "$0")/../../.." && pwd)
wrapper_src=$repo_dir/scripts/docker-ro-wrapper.sh

[ -f "$wrapper_src" ] || { echo "missing $wrapper_src" >&2; exit 1; }

if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: no docker CLI on PATH"
  exit 0
fi
if ! docker info >/dev/null 2>&1; then
  echo "SKIP: docker daemon not reachable"
  exit 0
fi

cname="docker-ro-realtest-$$"
pass=0
fail=0

cleanup() {
  docker rm -f "$cname" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "== resolve real docker binary =="
# The wrapper must find a real CLI on THIS host without help.
sh "$wrapper_src" version >/dev/null 2>&1
if [ $? -eq 0 ]; then
  printf '  ok   wrapper resolved a working docker binary\n'
  pass=$((pass + 1))
else
  printf '  FAIL wrapper could not resolve docker (this is the /snap/bin class of bug)\n'
  fail=$((fail + 1))
fi

echo "== provision a container with secret-shaped log lines =="
# Fixture secrets are OBVIOUSLY FAKE on purpose. Do not paste a real value
# here: this file is committed, and the point of the log filter is that real
# secrets should not end up in version control in the first place.
SECRET_A="claim-FIXTURE-NOT-A-REAL-TOKEN"
SECRET_B="000000:FIXTURE-NOT-A-REAL-BOT-TOKEN"
SECRET_C="sk-fixture-not-a-real-key"

docker rm -f "$cname" >/dev/null 2>&1 || true
if ! docker run -d --name "$cname" alpine:3 sh -c \
  'echo "booting up";
   echo "PLEX_CLAIM_TOKEN='"$SECRET_A"'";
   echo "connected to upstream";
   echo "ERROR: upstream refused connection";
   echo "TELEGRAM_BOT_TOKEN='"$SECRET_B"'";
   echo "warning: retry attempt 1";
   echo "API_KEY='"$SECRET_C"'";
   echo "fatal: giving up after 3 retries";
   sleep infinity' >/dev/null 2>&1; then
  echo "SKIP: could not start test container (image unavailable?)"
  exit 0
fi
sleep 2

# has <expected-substring> <label> <stdin-capture-file>
has() {
  substr=$1; label=$2; file=$3
  if grep -qF "$substr" "$file"; then
    printf '  ok   %-42s\n' "$label"; pass=$((pass + 1))
  else
    printf '  FAIL %-42s missing: %s\n' "$label" "$substr"; fail=$((fail + 1))
  fi
}
lacks() {
  substr=$1; label=$2; file=$3
  if grep -qF "$substr" "$file"; then
    printf '  FAIL %-42s LEAKED: %s\n' "$label" "$substr"; fail=$((fail + 1))
  else
    printf '  ok   %-42s\n' "$label"; pass=$((pass + 1))
  fi
}

work=$(mktemp -d "${TMPDIR:-/tmp}/docker-ro-real.XXXXXX")
trap 'cleanup; rm -rf "$work"' EXIT INT TERM

echo "== logs <id> is a whitelist: diagnostics kept, secrets dropped =="
sh "$wrapper_src" logs "$cname" > "$work/filtered" 2>&1

has  "ERROR: upstream refused connection" "error line survives"     "$work/filtered"
has  "warning: retry attempt 1"           "warning line survives"   "$work/filtered"
has  "fatal: giving up after 3 retries"   "fatal line survives"     "$work/filtered"

lacks "$SECRET_A" "plex claim token withheld"      "$work/filtered"
lacks "$SECRET_B" "telegram bot token withheld"    "$work/filtered"
lacks "$SECRET_C" "api key withheld"               "$work/filtered"
lacks "booting up" "benign non-diagnostic dropped" "$work/filtered"

echo "== confirm the secrets really ARE in the raw logs (test is not vacuous) =="
docker logs "$cname" > "$work/raw" 2>&1
has "$SECRET_A" "raw logs DO contain the secret" "$work/raw"
has "$SECRET_B" "raw logs DO contain the secret" "$work/raw"

echo "== logs-raw is refused unless explicitly enabled =="
sh "$wrapper_src" logs-raw "$cname" > "$work/rawrefused" 2>&1
if grep -qF "disabled" "$work/rawrefused"; then
  printf '  ok   %-42s\n' "logs-raw refused by default"; pass=$((pass + 1))
else
  printf '  FAIL %-42s not refused\n' "logs-raw refused by default"; fail=$((fail + 1))
fi

echo "== health <id> works on a real container =="
sh "$wrapper_src" health "$cname" > "$work/health" 2>&1 || true
if grep -qiE 'health|null|state' "$work/health"; then
  printf '  ok   %-42s\n' "health <id> returns inspect output"; pass=$((pass + 1))
else
  printf '  FAIL %-42s got: %s\n' "health <id>" "$(head -n1 "$work/health")"; fail=$((fail + 1))
fi

echo "== write verbs refused against a real daemon (container still running) =="
for verb in stop restart kill rm; do
  sh "$wrapper_src" "$verb" "$cname" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 64 ]; then
    printf '  ok   %-42s\n' "$verb refused (rc=64)"; pass=$((pass + 1))
  else
    printf '  FAIL %-42s rc=%s\n' "$verb refused" "$rc"; fail=$((fail + 1))
  fi
done
# The container must have survived all of that.
if docker inspect -f '{{.State.Running}}' "$cname" 2>/dev/null | grep -q true; then
  printf '  ok   %-42s\n' "container survived refused verbs"; pass=$((pass + 1))
else
  printf '  FAIL container was affected by a refused verb\n'; fail=$((fail + 1))
fi

printf '\ndocker-ro real-daemon: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
