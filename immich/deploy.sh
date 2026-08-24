#!/usr/bin/env bash
# Prepare and deploy the official Immich release on the host. Fails closed on prerequisites.
set -Eeuo pipefail
umask 077

ROOT=/opt/immich
STATE=$ROOT/state
APPROVED_BIND=$STATE/approved-bind-address
RELEASE_MANIFEST=$STATE/release-provenance.txt
COMPOSE_URL=${IMMICH_COMPOSE_URL:-}
ENV_URL=${IMMICH_ENV_URL:-}
EXPECTED_BIND=${IMMICH_BIND_ADDRESS:-}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

valid_ipv4() {
  local address=$1 a b c d extra octet
  IFS=. read -r a b c d extra <<< "$address"
  [[ -z ${extra:-} && -n ${a:-} && -n ${b:-} && -n ${c:-} && -n ${d:-} ]] || return 1
  for octet in "$a" "$b" "$c" "$d"; do
    [[ $octet =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$octet <= 255)) || return 1
  done
}

[[ $(uname -s) == Linux ]] || fail 'Immich deployment requires Linux'
command -v docker >/dev/null 2>&1 || fail 'Docker CLI is missing; install Docker Engine and Compose from official distribution instructions'
docker compose version >/dev/null 2>&1 || fail 'Docker Compose plugin is missing; install docker-compose-plugin from the official Docker repository'
docker info >/dev/null 2>&1 || fail 'Docker daemon is unavailable; start Docker before deployment'

[[ -f "$APPROVED_BIND" ]] || fail "approved bind artifact is required: $APPROVED_BIND"
[[ $(stat -c '%a' "$APPROVED_BIND") == 600 ]] || fail 'approved bind artifact must have mode 0600'
BIND=$(sed -n '1p' "$APPROVED_BIND")
[[ -n $BIND && $(wc -l < "$APPROVED_BIND") -eq 1 ]] || fail 'approved bind artifact must contain exactly one line'
valid_ipv4 "$BIND" || fail 'approved bind artifact must contain one valid IPv4 address, never a wildcard'
[[ -z $EXPECTED_BIND || $EXPECTED_BIND == "$BIND" ]] || fail 'IMMICH_BIND_ADDRESS does not match approved bind artifact'

mkdir -p "$ROOT" "$ROOT/postgres" "$ROOT/bin" "$ROOT/logs" "$ROOT/state" /srv/immich/library /srv/immich-migration/google-takeout
chmod 700 "$ROOT" "$ROOT/postgres" "$ROOT/bin" "$ROOT/logs" "$ROOT/state" /srv/immich /srv/immich/library /srv/immich-migration /srv/immich-migration/google-takeout

command -v curl >/dev/null 2>&1 || fail 'curl is required; wget fallback is intentionally not used by this controlled script'
if [[ -z $COMPOSE_URL || -z $ENV_URL ]]; then
  RELEASE_JSON=$(curl -fsSL --max-time 30 https://api.github.com/repos/immich-app/immich/releases/latest) || fail 'cannot resolve latest Immich release'
  TAG=$(printf '%s' "$RELEASE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])') || fail 'latest Immich release response was invalid'
  [[ $TAG =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'latest Immich release tag was not a stable semantic version'
  COMPOSE_URL="https://github.com/immich-app/immich/releases/download/$TAG/docker-compose.yml"
  ENV_URL="https://github.com/immich-app/immich/releases/download/$TAG/example.env"
else
  TAG=provided
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/immich-release.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT
curl -fL --max-time 120 "$COMPOSE_URL" -o "$TMP/docker-compose.yml" || fail 'official Compose download failed'
curl -fL --max-time 120 "$ENV_URL" -o "$TMP/example.env" || fail 'official example.env download failed'
[[ -s "$TMP/docker-compose.yml" && -s "$TMP/example.env" ]] || fail 'downloaded release files are empty'
grep -q 'services:' "$TMP/docker-compose.yml" || fail 'downloaded Compose file does not look like an official Compose file'
grep -q '^UPLOAD_LOCATION=' "$TMP/example.env" || fail 'downloaded env file does not look like official example.env'

# Keep the upstream file intact; stage all generated artifacts before any runtime replacement.
install -m 600 "$TMP/example.env" "$TMP/.env"
python3 - "$TMP/.env" <<'PY'
from pathlib import Path
import os, re, secrets, string, sys
p = Path(sys.argv[1])
text = p.read_text()
values = {
    'UPLOAD_LOCATION': '/srv/immich/library',
    'DB_DATA_LOCATION': '/opt/immich/postgres',
    'TZ': 'America/Los_Angeles',
    'IMMICH_VERSION': 'v3',
    'DB_USERNAME': 'postgres',
    'DB_DATABASE_NAME': 'immich',
    'DB_PASSWORD': ''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(48)),
}
for key, value in values.items():
    line = re.compile(rf'(?m)^[# ]*{re.escape(key)}=.*$')
    replacement = f'{key}={value}'
    if line.search(text): text = line.sub(replacement, text, count=1)
    else: text += f'\n{replacement}\n'
p.write_text(text)
PY
chmod 600 "$TMP/.env"
[[ $(grep -c '^DB_PASSWORD=[A-Za-z0-9]\{32,\}$' "$TMP/.env") == 1 ]] || fail 'generated database password failed policy'
cat > "$TMP/docker-compose.override.yml" <<EOF
services:
  immich-server:
    ports: !override
      - "$BIND:2283:2283"
EOF
chmod 600 "$TMP/docker-compose.override.yml"

COMPOSE=(docker compose -p immich --project-directory "$ROOT" --env-file "$TMP/.env" -f "$TMP/docker-compose.yml" -f "$TMP/docker-compose.override.yml")
"${COMPOSE[@]}" config --quiet || fail 'rendered Immich Compose configuration is invalid'
"${COMPOSE[@]}" config --format json > "$TMP/rendered.json"
python3 - "$TMP/rendered.json" "$BIND" <<'PY'
import json, ipaddress, sys
from pathlib import Path
rendered = json.loads(Path(sys.argv[1]).read_text())
bind = ipaddress.ip_address(sys.argv[2])
services = rendered.get('services', {})
server = services.get('immich-server')
if not server:
    raise SystemExit('immich-server service is missing')
ports = server.get('ports', [])
expected = False
for port in ports:
    if str(port.get('target')) == '2283' and str(port.get('published')) == '2283' and ipaddress.ip_address(str(port.get('host_ip'))) == bind:
        expected = True
    elif str(port.get('target')) != '2283' or str(port.get('published')) != '2283':
        raise SystemExit(f'unexpected immich-server published port: {port}')
if not expected:
    raise SystemExit('immich-server is not bound exactly to approved 2283 address')
for name, service in services.items():
    for port in service.get('ports', []):
        if name not in ('immich-server',) or str(port.get('target')) != '2283':
            raise SystemExit(f'unexpected published port on {name}: {port}')
for name in ('database', 'redis'):
    for port in services.get(name, {}).get('ports', []):
        raise SystemExit(f'database/redis must not publish host ports: {name}')
PY

# Commit the complete validated set only after the staged render succeeds.
install -m 644 "$TMP/docker-compose.yml" "$ROOT/docker-compose.yml.new"
install -m 600 "$TMP/docker-compose.override.yml" "$ROOT/docker-compose.override.yml.new"
install -m 600 "$TMP/.env" "$ROOT/.env.new"
{
  printf 'release_tag=%s\ncompose_url=%s\nenv_url=%s\n' "$TAG" "$COMPOSE_URL" "$ENV_URL"
  sha256sum "$TMP/docker-compose.yml" "$TMP/.env" | sed "s#  $TMP/##"
  printf 'approved_bind=%s\n' "$BIND"
  printf 'downloaded_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$TMP/release-provenance.txt"
chmod 600 "$TMP/release-provenance.txt"
install -m 600 "$TMP/release-provenance.txt" "$RELEASE_MANIFEST.new"
mv -f "$ROOT/docker-compose.yml.new" "$ROOT/docker-compose.yml"
mv -f "$ROOT/docker-compose.override.yml.new" "$ROOT/docker-compose.override.yml"
mv -f "$ROOT/.env.new" "$ROOT/.env"
mv -f "$RELEASE_MANIFEST.new" "$RELEASE_MANIFEST"

LIVE_COMPOSE=(docker compose -p immich --project-directory "$ROOT" --env-file "$ROOT/.env" -f "$ROOT/docker-compose.yml" -f "$ROOT/docker-compose.override.yml")
"${LIVE_COMPOSE[@]}" config --quiet || fail 'committed Immich runtime files failed final validation'
printf 'Official Immich files prepared under %s for release %s.\n' "$ROOT" "$TAG"
printf 'Review rendered configuration, then run: %s pull && %s up -d\n' "${LIVE_COMPOSE[*]}" "${LIVE_COMPOSE[*]}"
