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
#    validate`), and every service's mounts are cross-referenced against the
#    backup service's BACKUP_PATHS / BACKUP_VOLUMES / EXCLUDED_MOUNTS /
#    EXTRA_BACKUP_PATHS environment. A container added without backup coverage
#    fails here, as does a renamed volume or a drifted backup.yml mount.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
SCRIPT="$REPO/scripts/backup.sh"

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
dirA=$(mktemp -d)
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
dirB=$(mktemp -d)
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
dirC=$(mktemp -d)
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
  work=$(mktemp -d)
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
negdir=$(mktemp -d)
cp -R "$REPO/general" "$negdir/general"
if [ -f "$negdir/general/.env.example" ]; then cp "$negdir/general/.env.example" "$negdir/general/.env"; fi
TELEGRAM_BOT_TOKEN=ci-placeholder TELEGRAM_CHAT_ID=ci-placeholder \
  COUCHDB_USER=ci-placeholder COUCHDB_PASSWORD=ci-placeholder \
  docker compose --project-directory "$negdir/general" config --format json > "$negdir/cfg.json"
python3 - "$negdir/cfg.json" <<'EOF'
import json
import sys
cfg = json.load(open(sys.argv[1]))
env = cfg["services"]["backup"]["environment"]
env["BACKUP_PATHS"] = " ".join(
    p for p in env["BACKUP_PATHS"].split() if p != "/home/wbw/couchdb"
)
json.dump(cfg, open(sys.argv[1], "w"))
EOF
if python3 "$HERE/coverage_check.py" "$negdir/cfg.json" general "$negdir" >/dev/null 2>&1; then
  bad "negative control: checker did not flag the removed couchdb path"
else
  ok "negative control: checker flags a removed backup path"
fi
rm -rf "$negdir"

# Case D: end-to-end exclusion check. Builds a fake state tree, points
# PATH_ROOT at it, and takes a real --now snapshot with the general stack's
# excludes; the excluded patterns must not appear in the archive. This guards
# the zip pattern semantics (a pattern starting "*/" never matches, since
# zip's * requires at least one character before the literal slash).
dirD=$(mktemp -d)
fake="$dirD/backup-roots/home/wbw/docker"
mkdir -p "$fake/backups"
: > "$fake/config.yaml"
: > "$fake/backups/4a96b252.tar"
: > "$fake/home-assistant_v2.db.corrupt.2022-01-01"
: > "$fake/home-assistant.log.1"
ROLE=general DEST_DIR="$dirD" PATH_ROOT="$dirD/backup-roots" \
  BACKUP_PATHS=/home/wbw/docker BACKUP_VOLUMES= \
  EXCLUDES="*home-assistant_v2.db-wal *etc-pihole/*-wal *home-assistant_v2.db.corrupt.* *home/wbw/docker/backups/* *home-assistant.log*" \
  BACKUP_SOURCE_ONLY=1 sh -c ". '$SCRIPT'; run_backup --now" >/dev/null 2>&1
zipfile=$(ls "$dirD"/general-backup-*.zip 2>/dev/null | head -1)
if [ -n "$zipfile" ]; then
  for bad in "backups/4a96b252.tar" "home-assistant_v2.db.corrupt" "home-assistant.log.1"; do
    if unzip -l "$zipfile" | grep -q "$bad"; then
      bad "exclusions: $bad should not be in the archive"
    else
      ok "exclusions: $bad absent from archive"
    fi
  done
  unzip -l "$zipfile" | grep -q "config.yaml" \
    && ok "exclusions: included files still present" \
    || bad "exclusions: config.yaml missing from archive"
else
  bad "exclusions: no snapshot was created"
fi
rm -rf "$dirD"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
