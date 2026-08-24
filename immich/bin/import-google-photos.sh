#!/usr/bin/env bash
# Import Google Photos Takeout archives into Immich without placing the API key in argv or logs.
set -Eeuo pipefail
umask 077

IMMICH_BIN=${IMMICH_BIN:-/opt/immich/bin/immich-go}
TAKEOUT_DIR=${TAKEOUT_DIR:-/srv/immich-migration/google-takeout}
LOG_DIR=${LOG_DIR:-/opt/immich/logs}
STATE_DIR=${STATE_DIR:-/opt/immich/state}
IMMICH_SERVER=${IMMICH_SERVER:-http://127.0.0.1:2283}
CURL_BIN=${CURL_BIN:-curl}
MANAGE_RAW_JPEG=${MANAGE_RAW_JPEG:-StackCoverRaw}
MANAGE_HEIC_JPEG=${MANAGE_HEIC_JPEG:-StackCoverJPG}
MANAGE_BURST=${MANAGE_BURST:-Stack}

usage() {
  printf 'Usage: %s {dry-run|import}\n' "${0##*/}" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

case "${1:-}" in
  dry-run|import) MODE=$1 ;;
  *) usage; exit 2 ;;
esac

[[ -n ${IMMICH_API_KEY:-} ]] || die 'IMMICH_API_KEY is required in the environment'
[[ $IMMICH_API_KEY =~ ^[A-Za-z0-9._:-]+$ ]] || die 'IMMICH_API_KEY contains unsupported characters; refusing unsafe config generation'
[[ $IMMICH_SERVER =~ ^https?://[^[:space:]]+$ ]] || die 'IMMICH_SERVER must be an http(s) URL without whitespace'
[[ -x "$IMMICH_BIN" ]] || die "immich-go is unavailable: $IMMICH_BIN"
[[ -d "$TAKEOUT_DIR" ]] || die "Takeout directory is unavailable: $TAKEOUT_DIR"
command -v "$CURL_BIN" >/dev/null 2>&1 || die "curl is unavailable: $CURL_BIN"
[[ $MANAGE_RAW_JPEG =~ ^[A-Za-z0-9_-]+$ ]] || die 'MANAGE_RAW_JPEG contains unsafe characters'
[[ $MANAGE_HEIC_JPEG =~ ^[A-Za-z0-9_-]+$ ]] || die 'MANAGE_HEIC_JPEG contains unsafe characters'
[[ $MANAGE_BURST =~ ^[A-Za-z0-9_-]+$ ]] || die 'MANAGE_BURST contains unsafe characters'

mkdir -p "$LOG_DIR" "$STATE_DIR"
chmod 700 "$LOG_DIR" "$STATE_DIR"

mapfile -d '' -t ZIPS < <(find "$TAKEOUT_DIR" -maxdepth 1 -type f -name '*.zip' -print0)
((${#ZIPS[@]} > 0)) || die "no Takeout ZIP archives found in $TAKEOUT_DIR"

TOTAL_BYTES=0
for zip in "${ZIPS[@]}"; do
  bytes=$(stat -c '%s' -- "$zip") || die "cannot stat archive: $zip"
  TOTAL_BYTES=$((TOTAL_BYTES + bytes))
done

RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
SESSION_TAG=${IMMICH_IMPORT_TAG:-google-photos-$RUN_ID}
[[ $SESSION_TAG =~ ^[A-Za-z0-9._/-]+$ ]] || die 'IMMICH_IMPORT_TAG contains unsafe characters'
LOG_FILE="$LOG_DIR/google-photos-$RUN_ID.log"
REPORT_FILE="$STATE_DIR/google-photos-$RUN_ID-report.txt"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/immich-google-photos.XXXXXX")
chmod 700 "$TMP_DIR"
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT

# The key is stored only in mode-0600 temporary files and the child config.
# It is deliberately removed from the importer environment and never appears in argv.
HEADER_FILE="$TMP_DIR/api-header"
CONFIG_FILE="$TMP_DIR/immich-go.toml"
printf 'x-api-key: %s\n' "$IMMICH_API_KEY" > "$HEADER_FILE"
printf '[upload]\napi-key = '\''%s'\''\n' "$IMMICH_API_KEY" > "$CONFIG_FILE"
chmod 600 "$HEADER_FILE" "$CONFIG_FILE"

PING_FILE="$TMP_DIR/ping"
env -u IMMICH_API_KEY "$CURL_BIN" -fsS --max-time 15 -H "@$HEADER_FILE" "$IMMICH_SERVER/api/server/ping" -o "$PING_FILE" \
  || die "Immich connectivity check failed for $IMMICH_SERVER"

OUT_FILE="$TMP_DIR/import.stdout"
ERR_FILE="$TMP_DIR/import.stderr"
REDACT_FILE="$TMP_DIR/redact.sed"
# API keys are restricted above to characters that can be safely escaped for sed.
REDACT_PATTERN=${IMMICH_API_KEY//\\/\\\\}
REDACT_PATTERN=${REDACT_PATTERN//|/\\|}
REDACT_PATTERN=${REDACT_PATTERN//&/\\&}
REDACT_PATTERN=${REDACT_PATTERN//./\\.}
printf 's|%s|[REDACTED]|g\n' "$REDACT_PATTERN" > "$REDACT_FILE"
chmod 600 "$REDACT_FILE"

STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ARGS=(upload from-google-photos --server="$IMMICH_SERVER" --concurrent-tasks=4 --client-timeout=60m --pause-immich-jobs=true --on-errors=continue --session-tag --tag="$SESSION_TAG" --manage-raw-jpeg="$MANAGE_RAW_JPEG" --manage-heic-jpeg="$MANAGE_HEIC_JPEG" --manage-burst="$MANAGE_BURST")
if [[ $MODE == dry-run ]]; then
  ARGS+=(--dry-run)
fi
ARGS+=(-- "${ZIPS[@]}")

set +e
(
  cd "$TMP_DIR"
  env -u IMMICH_API_KEY "$IMMICH_BIN" "${ARGS[@]}" >"$OUT_FILE" 2>"$ERR_FILE"
)
IMPORT_RC=$?
set -e
ENDED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Persist only redacted importer output. Raw files remain in the private temporary directory.
{
  printf 'mode=%s\n' "$MODE"
  printf 'started_at=%s\nended_at=%s\n' "$STARTED_AT" "$ENDED_AT"
  printf 'server=%s\n' "$IMMICH_SERVER"
  printf 'zip_count=%s\ntotal_archive_bytes=%s\n' "${#ZIPS[@]}" "$TOTAL_BYTES"
  printf 'session_tag=%s\n' "$SESSION_TAG"
  printf 'import_exit_code=%s\n' "$IMPORT_RC"
  printf '%s\n' '--- importer findings (redacted) ---'
  sed -f "$REDACT_FILE" "$OUT_FILE" "$ERR_FILE" | grep -iE 'upload|asset|duplicate|skip|warning|unmatched|error|media|photo|video' || true
} > "$LOG_FILE"
chmod 600 "$LOG_FILE"
cp -- "$LOG_FILE" "$REPORT_FILE"
chmod 600 "$REPORT_FILE"

printf 'mode=%s zip_count=%s total_archive_bytes=%s report=%s exit_code=%s\n' "$MODE" "${#ZIPS[@]}" "$TOTAL_BYTES" "$REPORT_FILE" "$IMPORT_RC"
exit "$IMPORT_RC"
