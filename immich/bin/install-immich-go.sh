#!/usr/bin/env bash
# Download and install the architecture-matched stable immich-go release.
set -Eeuo pipefail
umask 077

DEST=${DEST:-/opt/immich/bin/immich-go}
STATE=${STATE:-/opt/immich/state}
VERSION=${IMMICH_GO_VERSION:-v0.32.0}
BASE_URL="https://github.com/simulot/immich-go/releases/download/${VERSION}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || fail 'curl is required'
command -v sha256sum >/dev/null 2>&1 || fail 'sha256sum is required'
[[ $(uname -s) == Linux ]] || fail 'this installer supports Linux only'
case "$(uname -m)" in
  x86_64|amd64) ASSET=immich-go_Linux_x86_64.tar.gz ;;
  aarch64|arm64) ASSET=immich-go_Linux_arm64.tar.gz ;;
  *) fail "unsupported architecture: $(uname -m)" ;;
esac

mkdir -p "$(dirname "$DEST")" "$STATE"
chmod 700 "$(dirname "$DEST")" "$STATE"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/immich-go.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
curl -fL --max-time 120 "$BASE_URL/$ASSET" -o "$tmp/$ASSET" || fail 'immich-go download failed'
[[ -s "$tmp/$ASSET" ]] || fail 'immich-go archive is empty'
printf 'sha256=%s\nversion=%s\nasset=%s\nurl=%s\n' "$(sha256sum "$tmp/$ASSET" | awk '{print $1}')" "$VERSION" "$ASSET" "$BASE_URL/$ASSET" > "$tmp/provenance"
chmod 600 "$tmp/provenance"
tar -xzf "$tmp/$ASSET" -C "$tmp" || fail 'immich-go archive extraction failed'
binary=$(find "$tmp" -maxdepth 2 -type f -name 'immich-go' -perm -u+x -print -quit)
[[ -n $binary ]] || fail 'immich-go binary was not found in archive'
install -m 0700 "$binary" "$DEST.new"
"$DEST.new" --version > "$tmp/version"
install -m 0700 "$DEST.new" "$DEST"
rm -f "$DEST.new"
install -m 0600 "$tmp/version" "$STATE/immich-go-version"
install -m 0600 "$tmp/provenance" "$STATE/immich-go-provenance.txt"
printf 'Installed immich-go %s at %s\n' "$VERSION" "$DEST"
