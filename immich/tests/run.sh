#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(CDPATH= cd -- "$ROOT/tests" && pwd)
MODE=${1:-}

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

[ "$MODE" = unit ] || [ "$MODE" = host ] || { echo "Usage: $0 unit|host" >&2; exit 2; }

if [ "$MODE" = unit ]; then
  command -v bash >/dev/null 2>&1 || fail 'bash is required for wrapper tests'
  command -v grep >/dev/null 2>&1 || fail 'grep is required'
  command -v find >/dev/null 2>&1 || fail 'find is required'
  command -v stat >/dev/null 2>&1 || fail 'stat is required'
  [ -x "$ROOT/bin/import-google-photos.sh" ] || fail 'wrapper is not executable'
  grep -q 'set -Eeuo pipefail' "$ROOT/bin/import-google-photos.sh" || fail 'wrapper lacks strict mode'
  grep -q 'env -u IMMICH_API_KEY' "$ROOT/bin/import-google-photos.sh" || fail 'wrapper does not remove key from importer environment'
  grep -q 'immich-go.toml' "$ROOT/bin/import-google-photos.sh" || fail 'wrapper lacks config-file transport'
  ! grep -q -- '--api-key' "$ROOT/bin/import-google-photos.sh" || fail 'wrapper places API key in argv'
  grep -q -- '--dry-run' "$ROOT/bin/import-google-photos.sh" || fail 'dry-run flag missing'
  grep -q -- '--concurrent-tasks=4' "$ROOT/bin/import-google-photos.sh" || fail 'conservative concurrency missing'
  grep -q -- '--client-timeout=60m' "$ROOT/bin/import-google-photos.sh" || fail 'client timeout missing'
  grep -q -- '--pause-immich-jobs=true' "$ROOT/bin/import-google-photos.sh" || fail 'job pause missing'
  grep -q -- '--on-errors=continue' "$ROOT/bin/import-google-photos.sh" || fail 'continue-on-error missing'
  ! grep -q -- '--overwrite' "$ROOT/bin/import-google-photos.sh" || fail 'overwrite must not be enabled'
  ! grep -q -- '--include-unmatched' "$ROOT/bin/import-google-photos.sh" || fail 'include-unmatched must not be enabled'
  grep -q 'Never delete Takeout archives' "$ROOT/README.md" || fail 'archive preservation is undocumented'
  grep -q 'Recurring Google Photos synchronization and public exposure are out of scope' "$ROOT/README.md" || fail 'scope boundary is undocumented'
  [ -f "$ROOT/PLEX_SECRET_REMEDIATION.md" ] || fail 'Plex remediation artifact missing'
  grep -q 'PLEX_CLAIM' "$ROOT/PLEX_SECRET_REMEDIATION.md" || fail 'Plex claim inventory missing'
  grep -q 'POSTGRES_PASSWORD' "$ROOT/PLEX_SECRET_REMEDIATION.md" || fail 'database password inventory missing'
  grep -q 'TELEGRAM' "$ROOT/PLEX_SECRET_REMEDIATION.md" || fail 'Telegram inventory missing'
  grep -q 'API_KEY' "$ROOT/PLEX_SECRET_REMEDIATION.md" || fail 'API key inventory missing'

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/immich-unit.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  takeout=$tmp/takeout
  mkdir -p "$takeout" "$tmp/logs" "$tmp/state"
  key='unit-test-key-9Z'
  fake_go=$TEST_ROOT/mocks/immich-go
  fake_curl=$TEST_ROOT/mocks/curl
  chmod 700 "$fake_go" "$fake_curl"

  set +e
  IMMICH_BIN=$fake_go TAKEOUT_DIR=$takeout LOG_DIR=$tmp/logs STATE_DIR=$tmp/state CURL_BIN=$fake_curl \
    "$ROOT/bin/import-google-photos.sh" dry-run >"$tmp/missing-key.out" 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail 'missing API key was accepted'
  grep -q 'IMMICH_API_KEY is required' "$tmp/missing-key.out" || fail 'missing-key diagnostic is wrong'

  set +e
  IMMICH_API_KEY=$key IMMICH_BIN=$fake_go TAKEOUT_DIR=$takeout LOG_DIR=$tmp/logs STATE_DIR=$tmp/state CURL_BIN=$fake_curl \
    "$ROOT/bin/import-google-photos.sh" dry-run >"$tmp/missing-zip.out" 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail 'missing archive was accepted'
  grep -q 'no Takeout ZIP archives' "$tmp/missing-zip.out" || fail 'missing-archive diagnostic is wrong'

  printf 'zip fixture\n' > "$takeout/part-001.zip"
  MOCK_ARGV=$tmp/argv MOCK_ENV_KEY=$tmp/env-key MOCK_CONFIG=$tmp/config \
    IMMICH_API_KEY=$key IMMICH_BIN=$fake_go TAKEOUT_DIR=$takeout LOG_DIR=$tmp/logs STATE_DIR=$tmp/state CURL_BIN=$fake_curl \
    "$ROOT/bin/import-google-photos.sh" dry-run >"$tmp/dry-run.out"
  grep -q 'mode=dry-run' "$tmp/dry-run.out" || fail 'dry-run did not report its mode'
  grep -q -- '--dry-run' "$tmp/argv" || fail 'dry-run flag was not passed'
  ! grep -q "$key" "$tmp/argv" || fail 'API key leaked into child argv'
  grep -q '<unset>' "$tmp/env-key" || fail 'API key leaked into child environment'
  grep -q "$key" "$tmp/config" || fail 'API key was not supplied through config transport'
  ! grep -R -F -q "$key" "$tmp/logs" "$tmp/state" "$tmp/dry-run.out" || fail 'API key leaked to logs/reports/diagnostics'
  [ -f "$takeout/part-001.zip" ] || fail 'dry-run removed source archive'
  pass 'repository, validation, mocked dry-run, and secret-boundary checks'
  exit 0
fi

command -v docker >/dev/null 2>&1 || fail 'Docker CLI is required for host tests'
docker compose version >/dev/null 2>&1 || fail 'Docker Compose plugin is required for host tests'
docker info >/dev/null 2>&1 || fail 'Docker daemon is required for host tests'
[ -f /opt/immich/docker-compose.yml ] || fail 'official Compose file is not deployed'
[ -f /opt/immich/.env ] || fail 'runtime env is not deployed'
[ "$(stat -c '%a' /opt/immich/.env)" = 600 ] || fail '/opt/immich/.env is not mode 0600'
[ -f /opt/immich/state/approved-bind-address ] || fail 'approved bind artifact missing'
[ "$(stat -c '%a' /opt/immich/state/approved-bind-address)" = 600 ] || fail 'approved bind artifact is not mode 0600'
BIND=$(sed -n '1p' /opt/immich/state/approved-bind-address)
[ -n "$BIND" ] && [ "$(wc -l < /opt/immich/state/approved-bind-address)" -eq 1 ] || fail 'approved bind artifact must contain exactly one line'
python3 - "$BIND" <<'PY' || exit 1
import ipaddress, sys
try: ipaddress.IPv4Address(sys.argv[1])
except ValueError: raise SystemExit('invalid approved IPv4 address')
PY
cd /opt/immich
COMPOSE="docker compose -p immich --project-directory /opt/immich --env-file /opt/immich/.env -f /opt/immich/docker-compose.yml -f /opt/immich/docker-compose.override.yml"
$COMPOSE config --quiet
$COMPOSE config --format json > /tmp/immich-rendered.json
python3 - "/tmp/immich-rendered.json" "$BIND" <<'PY'
import json, ipaddress, sys
from pathlib import Path
d = json.loads(Path(sys.argv[1]).read_text()); bind = ipaddress.IPv4Address(sys.argv[2]); services = d.get('services', {})
server = services.get('immich-server') or (_ for _ in ()).throw(SystemExit('immich-server missing'))
ports = server.get('ports', []); expected = False
for p in ports:
    if str(p.get('target')) == '2283' and str(p.get('published')) == '2283' and ipaddress.ip_address(str(p.get('host_ip'))) == bind: expected = True
    else: raise SystemExit(f'unexpected immich-server port: {p}')
if not expected: raise SystemExit('approved HTTP bind missing')
for name, service in services.items():
    for p in service.get('ports', []):
        if name != 'immich-server': raise SystemExit(f'unexpected published port on {name}: {p}')
for name in ('database', 'redis'):
    if services.get(name, {}).get('ports'): raise SystemExit(f'host port on {name}')
PY
$COMPOSE ps
PORT=$($COMPOSE port immich-server 2283)
printf '%s\n' "$PORT" | grep -Fq "$BIND:2283" || fail 'published port does not match approved bind'
curl -fsS --max-time 15 "http://$BIND:2283/api/server/ping" >/dev/null
ss -lntp | grep -Fq "$BIND:2283" || fail 'approved HTTP socket is not listening'
pass 'host deployment checks'
