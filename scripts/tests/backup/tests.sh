#!/bin/sh
# Test suite for scripts/backup.sh and backup coverage.
#
# Run from anywhere:  sh scripts/tests/backup/tests.sh
# Or via the Makefile:  make test
#
# Two parts:
#
# 1. Function-level tests of the retention algorithm, run against the real
#    script sourced in a scratch DEST_DIR (BACKUP_SOURCE_ONLY=1 keeps main()
#    quiet). Expected survivor sets are hand-computed, not reimplemented.
#
# 2. Coverage tests: for each stack, `docker compose config` is resolved in a
#    throwaway copy (placeholders instead of secrets, same trick as `make
#    validate`), and every service's mounts plus required archive files are
#    cross-referenced against the backup service's declarations. Compose
#    healthcheck/autoheal invariants are also checked for the media stack.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
SCRIPT="$REPO/scripts/backup.sh"

# Scratch directories are created under the repository rather than in /tmp.
# The snap-packaged docker (Ubuntu's default here) is confined to $HOME and
# cannot read /tmp, so a /tmp scratch copy makes `docker compose config` fail
# with "no configuration file provided" — an error that looks like a real
# config problem and hides whatever the suite was actually testing. An
# explicitly set TMPDIR is still honored.
scratch_root="${TMPDIR:-$REPO}"
mktemp_d() { mktemp -d "$scratch_root/.test-scratch.XXXXXX"; }
# Sweep any scratch dir left behind by an early exit. The individual tests
# remove their own directories; this covers the paths where the suite stops
# before reaching them.
trap 'rm -rf "$scratch_root"/.test-scratch.*' EXIT INT TERM

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; }
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$2], got [$3])"; fi
}

command -v docker >/dev/null || { echo "FATAL: docker is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "FATAL: python3 is required" >&2; exit 1; }
command -v zip >/dev/null || { echo "FATAL: zip is required" >&2; exit 1; }
command -v unzip >/dev/null || { echo "FATAL: unzip is required" >&2; exit 1; }
[ -f "$SCRIPT" ] || { echo "FATAL: missing $SCRIPT" >&2; exit 1; }

# The coverage tests below run `docker compose config` against a scratch copy of
# each stack. If the docker CLI cannot read that copy at all, every stack fails
# with the same misleading "no configuration file provided" error and the suite
# looks like it is reporting config problems when it is really reporting a
# confinement problem. Fail once, clearly, before that happens.
docker_can_read() {
  probe=$(mktemp_d)/compose.yaml
  : > "$probe"
  err=$(docker compose -f "$probe" config -q 2>&1)
  case "$err" in
    *"no such file or directory"*)
      echo "FATAL: the docker CLI cannot read files under $scratch_root." >&2
      echo "       Snap-packaged docker is confined to \$HOME and cannot read /tmp;" >&2
      echo "       set TMPDIR to a directory under \$HOME, or use the distro docker." >&2
      return 1 ;;
  esac
  return 0
}
docker_can_read || exit 1

# ---------------------------------------------------------------------------
# Part 1: retention
# ---------------------------------------------------------------------------
run_prune() { # $1 = dest dir
  ROLE=general DEST_DIR="$1" KEEP_DAILY=7 KEEP_WEEKLY=11 KEEP_MONTHLY=9 \
    BACKUP_SOURCE_ONLY=1 sh -c ". '$SCRIPT'; prune_backups" >/dev/null 2>&1
}

# Case A: ten consecutive daily zips plus two older monthly-spaced ones.
# Expected: the newest 7 days survive; Oct 3, Oct 2 and Oct 1 fall outside the
# daily window and their week (Sep 28 - Oct 4) is not strictly older than the
# oldest daily's (Oct 4), so they are dropped; Sep 1 and Aug 1 are each the
# newest zip of their (older) week and survive as weeklies.
dirA=$(mktemp_d)
for i in 01 02 03 04 05 06 07 08 09 10; do
  : > "$dirA/general-backup-202610${i}T120000Z.zip"
done
: > "$dirA/general-backup-20260901T120000Z.zip"
: > "$dirA/general-backup-20260801T120000Z.zip"
run_prune "$dirA"
assert_eq "retention: 10-day fixture keeps 9" "9" "$(ls -1 "$dirA" | wc -l | tr -d ' ')"
for keep in 20260801 20260901 20261004 20261005 20261006 20261007 20261008 20261009 20261010; do
  [ -f "$dirA/general-backup-${keep}T120000Z.zip" ] || bad "retention: expected survivor $keep missing"
done
[ "$(ls -1 "$dirA" | wc -l)" = "9" ] && ok "retention: exact survivor set (A)" \
  || bad "retention: unexpected survivors: $(ls -1 "$dirA" | tr '\n' ' ')"
rm -rf "$dirA"

# Case B: a dense year of daily zips must collapse to exactly 27 distinct
# restore points, and a second prune must be a no-op.
dirB=$(mktemp_d)
for i in $(seq 0 364); do
  : > "$dirB/general-backup-$(date -u -d "2026-01-01 +$i days" +%Y%m%d)T120000Z.zip"
done
run_prune "$dirB"
assert_eq "retention: dense year keeps 27" "27" "$(ls -1 "$dirB" | wc -l | tr -d ' ')"
before=$(ls -1 "$dirB")
run_prune "$dirB"
assert_eq "retention: second prune is a no-op" "$before" "$(ls -1 "$dirB")"
rm -rf "$dirB"

# Case C: non-conforming names are never touched.
dirC=$(mktemp_d)
: > "$dirC/general-backup-20261005T120000Z.zip"
: > "$dirC/general-backup-garbage.zip" # matches the glob but not the timestamp format
: > "$dirC/unrelated.zip"
: > "$dirC/media-backup-20261005T120000Z.zip" # other server's prefix
run_prune "$dirC"
for preserve in general-backup-garbage.zip unrelated.zip media-backup-20261005T120000Z.zip; do
  [ -f "$dirC/$preserve" ] && ok "retention: preserved $preserve" \
    || bad "retention: deleted non-conforming file $preserve"
done
rm -rf "$dirC"

# ---------------------------------------------------------------------------
# Part 2: per-stack coverage
# ---------------------------------------------------------------------------
check_stack() { # $1 = stack directory name
  stack=$1
  work=$(mktemp_d)
  cp -R "$REPO/$stack" "$work/$stack"
  if [ -f "$work/$stack/.env.example" ]; then
    cp "$work/$stack/.env.example" "$work/$stack/.env"
  fi

  # Required variables for stacks whose .env.example does not cover them
  # (mirrors the placeholder values CI uses for `docker compose config`).
  TELEGRAM_BOT_TOKEN=ci-placeholder \
  TELEGRAM_CHAT_ID=ci-placeholder \
  COUCHDB_USER=ci-placeholder \
  COUCHDB_PASSWORD=ci-placeholder \
  docker compose --project-directory "$work/$stack" config --format json > "$work/cfg.json" 2>"$work/err.txt" || {
    bad "$stack: compose config failed: $(cat "$work/err.txt")"
    rm -rf "$work"
    return 1
  }

  if python3 "$HERE/coverage_check.py" "$work/cfg.json" "$stack" "$work"; then
    ok "$stack: backup coverage covers every deployed service"
  else
    bad "$stack: backup coverage has gaps (see above)"
  fi
  rm -rf "$work"
}
check_stack general
check_stack media

# Negative control: drop one path from general's BACKUP_PATHS and confirm the
# checker catches the resulting gap. Guards against a future refactor silently
# weakening the coverage logic itself.
negdir=$(mktemp_d)
cp -R "$REPO/general" "$negdir/general"
if [ -f "$negdir/general/.env.example" ]; then cp "$negdir/general/.env.example" "$negdir/general/.env"; fi
TELEGRAM_BOT_TOKEN=ci-placeholder TELEGRAM_CHAT_ID=ci-placeholder \
  COUCHDB_USER=ci-placeholder COUCHDB_PASSWORD=ci-placeholder \
  docker compose --project-directory "$negdir/general" config --format json > "$negdir/cfg.json" 2>"$negdir/config.err" || {
    bad "negative control: compose config failed: $(cat "$negdir/config.err")"
    rm -rf "$negdir"
    exit 1
  }
python3 - "$negdir/cfg.json" <<'EOF'
import json
import sys
cfg = json.load(open(sys.argv[1]))
env = cfg["services"]["backup"]["environment"]
env["BACKUP_PATHS"] = " ".join(
    p for p in env["BACKUP_PATHS"].split() if p != "/mnt/halfToshibaB/docker/data/couchdb"
)
json.dump(cfg, open(sys.argv[1], "w"))
EOF
if python3 "$HERE/coverage_check.py" "$negdir/cfg.json" general "$negdir" >/dev/null 2>&1; then
  bad "negative control: checker did not flag the removed couchdb path"
else
  ok "negative control: checker flags a removed backup path"
fi
rm -rf "$negdir"

# Media negative controls: required dump coverage and the service health/autoheal
# contract must fail closed when a declaration drifts.
mediadir=$(mktemp_d)
cp -R "$REPO/media" "$mediadir/media"
TELEGRAM_BOT_TOKEN=ci-placeholder TELEGRAM_CHAT_ID=ci-placeholder \
  PIA_USER=ci-placeholder PIA_PASS=ci-placeholder \
  FRIGATE_RTSP_PASSWORD=ci-placeholder POSTGRES_PASSWORD=ci-placeholder \
  PLEX_CLAIM=ci-placeholder SONARR_API_KEY=ci-placeholder RADARR_API_KEY=ci-placeholder \
  SAB_API_KEY=ci-placeholder PLUS_API_KEY=ci-placeholder \
  IMMICH_VERSION=v3.1.0 IMMICH_DB_PASSWORD=ci-placeholder \
  PHOTO_UPLOADER_OPERATOR_USERNAME=ci-placeholder PHOTO_UPLOADER_OPERATOR_PASSWORD=ci-placeholder \
  PHOTO_UPLOADER_SESSION_SECRET=ci-placeholder PHOTO_UPLOADER_BSKY_HANDLE=ci-placeholder \
  PHOTO_UPLOADER_BSKY_APP_PASSWORD=ci-placeholder PHOTO_UPLOADER_PHOTO_PATH=/tmp \
  docker compose --project-directory "$mediadir/media" config --format json > "$mediadir/cfg.json" || {
    bad "media negative controls: compose config failed"
  }
python3 - "$mediadir/cfg.json" "$mediadir" <<'PY'
import copy, json, sys
cfg = json.load(open(sys.argv[1]))
root = sys.argv[2]
cases = {}

case = copy.deepcopy(cfg)
env = case["services"]["backup"]["environment"]
env["BACKUP_PATHS"] = " ".join(p for p in env["BACKUP_PATHS"].split() if p != "/bigdisk/db-dumps")
cases["missing-required-dump-coverage"] = case

case = copy.deepcopy(cfg)
case["services"]["whisparr"]["labels"].pop("autoheal", None)
cases["whisparr-autoheal-label"] = case

case = copy.deepcopy(cfg)
case["services"]["whisparr"].pop("healthcheck", None)
cases["whisparr-healthcheck"] = case

case = copy.deepcopy(cfg)
case["services"]["immich-server"].setdefault("labels", {})["autoheal"] = "true"
cases["immich-server-autoheal-exclusion"] = case

case = copy.deepcopy(cfg)
case["services"]["immich-db-dump"]["healthcheck"]["test"] = ["CMD-SHELL", "true"]
cases["immich-dump-freshness-check"] = case

for name, case in cases.items():
    json.dump(case, open(f"{root}/{name}.json", "w"))
PY
for case in missing-required-dump-coverage whisparr-autoheal-label whisparr-healthcheck immich-server-autoheal-exclusion immich-dump-freshness-check; do
  if python3 "$HERE/coverage_check.py" "$mediadir/$case.json" media "$mediadir" >/dev/null 2>&1; then
    bad "media invariant negative control: $case was not detected"
  else
    ok "media invariant negative control: $case detected"
  fi
done
rm -rf "$mediadir"

# Media dump archive smoke test: the declared SQL restore points must survive
# the real backup script's staging/zip path. Freshness is tested separately by
# the dump service healthchecks, not by this static fixture.
dumpfixture=$(mktemp_d)
mkdir -p "$dumpfixture/backup-roots/bigdisk/db-dumps"
printf 'postgres fixture dump\\n' > "$dumpfixture/backup-roots/bigdisk/db-dumps/postgres-all.sql"
printf 'immich fixture dump\\n' > "$dumpfixture/backup-roots/bigdisk/db-dumps/immich-all.sql"
ROLE=media DEST_DIR="$dumpfixture" PATH_ROOT="$dumpfixture/backup-roots" \
  BACKUP_PATHS="/bigdisk/db-dumps" BACKUP_VOLUMES= EXCLUDES= \
  BACKUP_SOURCE_ONLY=1 sh -c ". '$SCRIPT'; run_backup --now" >/dev/null 2>&1
media_zip=$(ls "$dumpfixture"/media-backup-*.zip 2>/dev/null | head -1)
if [ -n "$media_zip" ]; then
  for dump in bigdisk/db-dumps/postgres-all.sql bigdisk/db-dumps/immich-all.sql; do
    unzip -l "$media_zip" | grep -q "$dump" \
      && ok "media archive includes $dump" \
      || bad "media archive missing $dump"
  done
else
  bad "media archive dump fixture: no snapshot was created"
fi
rm -rf "$dumpfixture"

# Case D: end-to-end exclusion check. Resolve EXCLUDES from general's actual
# Compose config, then take a real --now snapshot of fake bind and named-volume
# state. This guards zip pattern semantics across both archive layouts.
dirD=$(mktemp_d)
# Case D fixtures mirror the deployed layout: HA state under
# /mnt/halfToshibaB/docker/data, job-digest state under job-digest/state,
# plus a named-volume staging tree. Resolving EXCLUDES from the real compose
# config keeps this test tied to backup.yml rather than a second copy.
fake="$dirD/backup-roots/mnt/halfToshibaB/docker/data"
jobfake="$fake/job-digest/state"
mkdir -p "$fake/homeassistant/backups" "$fake/homeassistant/diagnostic.data" "$jobfake/production-artifacts/run-1"
: > "$fake/homeassistant/config.yaml"
: > "$fake/homeassistant/backups/4a96b252.tar"
: > "$fake/homeassistant/home-assistant_v2.db.corrupt.2022-01-01"
: > "$fake/homeassistant/home-assistant_v2.db-wal.corrupt.2022-01-01"
: > "$fake/homeassistant/home-assistant_v2.db-shm.corrupt.2022-01-01"
: > "$fake/homeassistant/home-assistant.log.1"
: > "$fake/homeassistant/diagnostic.data/metrics.20261001T000000Z"
: > "$jobfake/production-artifacts/run-1/fetched.json"
# Real durable job-digest state files (see general/job-digest.yml);
# hn-cache.json is a real file the service rewrites daily.
: > "$jobfake/hn-cache.json"
volfake="$dirD/volume-roots/komodo-mongo-data"
mkdir -p "$volfake/diagnostic.data"
: > "$volfake/diagnostic.data/metrics.20261001T000000Z"
# A durable file in the named volume, to assert the volume itself is archived.
: > "$volfake/WiredTiger.wt"
negdir=$(mktemp_d)
cp -R "$REPO/general" "$negdir/general"
if [ -f "$negdir/general/.env.example" ]; then cp "$negdir/general/.env.example" "$negdir/general/.env"; fi
TELEGRAM_BOT_TOKEN=ci-placeholder TELEGRAM_CHAT_ID=ci-placeholder \
COUCHDB_USER=ci-placeholder COUCHDB_PASSWORD=ci-placeholder \
docker compose --project-directory "$negdir/general" config --format json > "$dirD/general-config.json"
excludes=$(python3 - "$dirD/general-config.json" <<'EOF'
import json, sys
print(json.load(open(sys.argv[1]))["services"]["backup"]["environment"]["EXCLUDES"])
EOF
)
rm -rf "$negdir"
ROLE=general DEST_DIR="$dirD" PATH_ROOT="$dirD/backup-roots" \
  VOLUME_ROOT="$dirD/volume-roots" \
  BACKUP_PATHS="/mnt/halfToshibaB/docker/data/homeassistant /mnt/halfToshibaB/docker/data/job-digest" \
  BACKUP_VOLUMES=komodo-mongo-data EXCLUDES="$excludes" \
  BACKUP_SOURCE_ONLY=1 sh -c ". '$SCRIPT'; run_backup --now" 2>"$dirD/run-backup.err" >/dev/null
zipfile=$(ls "$dirD"/general-backup-*.zip 2>/dev/null | head -1)
if [ -z "$zipfile" ]; then
  bad "exclusions: no snapshot was created"
  sed 's/^/      /' "$dirD/run-backup.err" >&2
else
  for bad in "homeassistant/backups/4a96b252.tar" "home-assistant_v2.db.corrupt" "home-assistant_v2.db-wal.corrupt" "home-assistant_v2.db-shm.corrupt" "home-assistant.log.1" "diagnostic.data/metrics" "production-artifacts/run-1/fetched.json"; do
    if unzip -l "$zipfile" | grep -q "$bad"; then
      bad "exclusions: $bad should not be in the archive"
    else
      ok "exclusions: $bad absent from archive"
    fi
  done
  unzip -l "$zipfile" | grep -q "homeassistant/config.yaml" \
    && ok "exclusions: included files still present" \
    || bad "exclusions: config.yaml missing from archive"
  unzip -l "$zipfile" | grep -q "job-digest/state/hn-cache.json" \
    && ok "exclusions: durable job-digest state remains included" \
    || bad "exclusions: durable job-digest state missing from archive"
  unzip -l "$zipfile" | grep -q "docker-volumes/komodo-mongo-data/WiredTiger.wt" \
    && ok "exclusions: named-volume durable state remains included" \
    || bad "exclusions: named-volume durable state missing from archive"
fi
rm -rf "$dirD"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
