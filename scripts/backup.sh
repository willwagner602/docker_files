#!/bin/sh
# Daily in-container backup for a Compose stack (ROLE=general|media).
#
# Runs inside the stack's "backup" service (see <stack>/backup.yml, image
# docker:29-cli). All protected state is mounted READ-ONLY, so the container
# needs no docker socket and cannot damage the live system:
#
#   PATH_ROOT (default /backup-roots)  host paths, preserving the host layout
#   VOLUME_ROOT (default /volume-roots) named volumes, one dir per volume name
#
# Everything the backup must cover is declared in the backup service's
# environment (BACKUP_PATHS / BACKUP_VOLUMES), which doubles as the machine
# readable coverage manifest checked by scripts/tests/backup/tests.sh: the test
# cross-references that list against every other service's resolved mounts, so
# a new container whose state is not backed up fails CI and `make test`.
#
# Scheduling: sleeps until BACKUP_AT (default 04:00, container-local time via
# TZ), then repeats daily. Retention is grandfather-father-son:
# KEEP_DAILY/KEEP_WEEKLY/KEEP_MONTHLY (default 7/11/9 = 27 restore points).
#
# Manual run, e.g. for a stop-first consistent copy of the databases:
#   docker compose stop couchdb unifi-db
#   docker compose run --rm -e BACKUP_NOW=1 backup
#   docker compose start couchdb unifi-db
#
# Output: $DEST_DIR/$ROLE-backup-YYYYMMDDTHHMMSSZ.zip, mirroring the host
# layout, with named volumes under docker-volumes/<volume-name> and a
# backup-manifest.txt declaring what the snapshot covers.
set -eu

PATH_ROOT=${PATH_ROOT:-/backup-roots}
VOLUME_ROOT=${VOLUME_ROOT:-/volume-roots}

ROLE=${ROLE:?ROLE not set (general or media)}
DEST_DIR=${DEST_DIR:?DEST_DIR not set}
BACKUP_PATHS=${BACKUP_PATHS:-}
BACKUP_VOLUMES=${BACKUP_VOLUMES:-}
BACKUP_AT=${BACKUP_AT:-04:00}
KEEP_DAILY=${KEEP_DAILY:-7}
KEEP_WEEKLY=${KEEP_WEEKLY:-11}
KEEP_MONTHLY=${KEEP_MONTHLY:-9}
# Defaults used by stacks that do not set EXCLUDES (currently media). A stack
# that sets EXCLUDES replaces this entire list; values are not merged.
# Patterns passed to zip -x. SQLite main databases are re-copied during
# staging (sqlite_restage below: a consistent snapshot via sqlite3 -readonly
# and VACUUM INTO), which folds any WAL
# frames in, so the WAL/SHM side files are redundant in the archive and
# excluded everywhere; media's Postgres databases go through pg_dump exports
# instead. NOTE: patterns must NOT start with "*/" — zip's matcher needs * to
# consume at least one character, so a leading "*/" never matches a relative
# archive path.
EXCLUDES=${EXCLUDES:-*home-assistant_v2.db-wal *home-assistant_v2.db-shm *ipc-socket}
# *ipc-socket: runtime IPC sockets (e.g. qBittorrent's config/config/ipc-socket)
# are not backup state; cp -a preserves them into staging and zip fails to
# read them ("zip warning: No such device or address").

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }
warn() { log "WARNING: $*" >&2; }

usage() {
  echo "Usage: sh /backup.sh [--now]"
  echo "  --now       take one snapshot immediately, then exit (no retention changes beyond the usual prune)"
  echo "  BACKUP_NOW=1 has the same effect when set in the environment (for Compose one-off runs)"
}

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------

# Re-copy every SQLite database found in a staged tree through sqlite3's
# .backup command, replacing the cp -a output with a consistent snapshot read
# from the live source. A plain cp of a hot SQLite database can tear across a
# concurrent write and misses committed WAL frames until the next checkpoint;
# a consistent snapshot through SQLite's own library (VACUUM INTO from a
# -readonly connection) is taken while the app keeps running. Sources stay
# read-only. Failures are loud: an inconsistent
# database in the archive is worse than a missing archive, so any SQLite
# database that cannot be snapshotted fails the whole backup run.
sqlite_restage() (
  src_root=$1
  staged_root=$2
  list=$(mktemp "${TMPDIR:-/tmp}/sqlite-restage.XXXXXX")
  trap 'rm -f "$list"' EXIT
  # Known limitation: a filename containing an embedded newline cannot be
  # expressed by this one-path-per-line loop and would be skipped silently.
  # No such file has ever been observed in the staged trees (app-owned names:
  # plex, arr, frigate, pihole), and the POSIX toolset on the Alpine backup
  # image offers no NUL-aware line consumer to detect one portably — the
  # known-empty guard costs more than it protects.

  find "$staged_root" -type f > "$list"
  status=0
  while IFS= read -r staged; do
    # Only main database files carry the 16-byte magic string; WAL/SHM side
    # files do not, so they are left as staged and stay excluded via EXCLUDES.
    [ "$(head -c 15 "$staged" 2>/dev/null)" = "SQLite format 3" ] || continue
    if ! command -v sqlite3 >/dev/null 2>&1; then
      echo "ERROR: $staged is a SQLite database but sqlite3 is not installed; refusing to archive an inconsistent hot copy" >&2
      return 1
    fi
    rel=${staged#"$staged_root"}
    live="$src_root$rel"
    rm -f "$staged"
    # Source path goes as a plain argv (no file: URI): SQLite's URI parser
    # treats ?/#/% as metacharacters, so an odd filename could change the
    # parse. -readonly keeps the read-only contract (an open that would want
    # to recover a crashed writer's WAL fails here, loudly, rather than
    # mutating live state); .timeout rides out brief writer locks.
    # Target goes through VACUUM INTO with SQL escaping ('' doubling), not
    # the .backup dot-command: the dot-command's quoting breaks on the
    # apostrophes and spaces these media trees' names contain, which either
    # aborted the run or silently archived an empty database. VACUUM INTO
    # produces the same full consistent snapshot (verified against a live
    # WAL writer) and takes an SQL string, where ordinary escaping applies.
    # It requires the target not to exist, which the rm above guarantees.
    staged_sql=$(printf "%s" "$staged" | sed "s/'/''/g")
    if ! sqlite3 -cmd ".timeout 10000" -readonly "$live" "VACUUM INTO '$staged_sql'"; then
      echo "ERROR: sqlite3 VACUUM INTO failed for $live; not archiving a possibly inconsistent copy" >&2
      status=1
      continue
    fi
    log "sqlite .backup: ${rel#/}"
  done < "$list"
  return "$status"
)

# Take one snapshot. Runs in a subshell so the cleanup trap never touches the
# scheduler loop. The lock directory prevents a manual --now run from racing
# the nightly scheduler of the same stack. It defaults to DEST_DIR; stacks
# whose destination is a synced/cloud folder can point BACKUP_LOCK_DIR at a
# local directory instead, keeping the lock out of the synced tree entirely
# (media does this — its lock must never reach Google Drive, and each host's
# lock is then its own business).
run_backup() (
  # Absolutize DEST_DIR before any cd: $staging is computed from it and used
  # after descending into the staging dir, so a relative DEST_DIR (test
  # harness scratch dirs) would resolve inside $work and fail zip.
  case $DEST_DIR in /*) ;; *) DEST_DIR="$PWD/$DEST_DIR" ;; esac
  mkdir -p "$DEST_DIR"
  lock_dir=${BACKUP_LOCK_DIR:-$DEST_DIR}
  mkdir -p "$lock_dir"
  lock="$lock_dir/.backup-lock"
  if ! mkdir "$lock" 2>/dev/null; then
    if [ -d "$lock" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +720)" ]; then
      warn "stale lock (over 12h old) found; stealing it"
      rmdir "$lock" 2>/dev/null || { warn "another backup is running; aborting"; return 1; }
      mkdir "$lock" 2>/dev/null || { warn "cannot recreate lock after steal; aborting"; return 1; }
    else
      warn "another backup is running; aborting"
      return 1
    fi
  fi
  trap 'rmdir "$lock" 2>/dev/null' EXIT
  echo $$ > "$lock/pid"

  ts=$(date -u +%Y%m%dT%H%M%SZ)
  final="$DEST_DIR/$ROLE-backup-$ts.zip"
  staging="$final.part"
  work=$(mktemp -d "${TMPDIR:-/tmp}/$ROLE-backup.XXXXXX")
  # One trap for everything; it fires when the subshell exits (early failure
  # included) and after the final mv. rm -rf (not rmdir) because the lock holds
  # a pid file.
  trap 'rm -rf "$work" "$lock" 2>/dev/null' EXIT INT TERM

  # Clean up a previously interrupted run's partial file.
  rm -f "$DEST_DIR/$ROLE-backup-"*".part" 2>/dev/null || true

  for path in $BACKUP_PATHS; do
    src="$PATH_ROOT$path"
    if [ ! -e "$src" ]; then
      warn "skipping missing path $path"
      continue
    fi
    mkdir -p "$work$(dirname "$path")"
    cp -a "$src" "$work$path"
    sqlite_restage "$src" "$work$path" || return 1
    log "copied $path ($(du -sh "$src" 2>/dev/null | cut -f1))"
  done

  for volume in $BACKUP_VOLUMES; do
    src="$VOLUME_ROOT/$volume"
    if [ ! -d "$src" ]; then
      warn "skipping missing volume $volume"
      continue
    fi
    mkdir -p "$work/docker-volumes/$volume"
    cp -a "$src/." "$work/docker-volumes/$volume/"
    sqlite_restage "$src" "$work/docker-volumes/$volume" || return 1
    log "copied volume $volume ($(du -sh "$src" 2>/dev/null | cut -f1))"
  done

  {
    echo "role: $ROLE"
    echo "host: $(hostname)"
    echo "created: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "paths: $BACKUP_PATHS"
    echo "volumes: $BACKUP_VOLUMES"
    echo "excluded patterns: $EXCLUDES"
  } > "$work/backup-manifest.txt"

  # Disable globbing while splitting EXCLUDES: patterns like */foo/bar/* must
  # reach zip literally, not be expanded against the current directory (in the
  # container that is /, where the read-only state mounts live).
  set -f
  set --            # rebuild "$@" as the zip exclude arguments
  for pattern in $EXCLUDES; do
    set -- "$@" -x "$pattern"
  done
  set +f
  (cd "$work" && zip -qr9 "$staging" . "$@")
  mv "$staging" "$final"
  log "backup complete: $final ($(du -h "$final" | cut -f1))"
)

# ---------------------------------------------------------------------------
# Retention (grandfather-father-son)
# ---------------------------------------------------------------------------
# Buckets come from the UTC timestamp in the filename. Tiers are sequential,
# not overlapping: the 7 dailies are the newest distinct days; the 11 weeklies
# are the newest zip of each distinct week strictly BEFORE the oldest daily's
# week; the 9 monthlies are the newest zip of each distinct month strictly
# before the oldest weekly's month. That yields KEEP_DAILY + KEEP_WEEKLY +
# KEEP_MONTHLY = 27 distinct restore points (with dense daily history; sparse
# history keeps fewer). Weeks are 7-day buckets anchored to Monday
# ((days + 3) / 7: 1970-01-01 was a Thursday).
prune_backups() {
  [ -d "$DEST_DIR" ] || return 0
  files=$(ls -1 "$DEST_DIR" 2>/dev/null | grep "^$ROLE-backup-.*\.zip$" | sort -r) || return 0
  [ -n "$files" ] || return 0

  printf '%s\n' "$files" | TZ=UTC awk \
    -v role="$ROLE" -v kd="$KEEP_DAILY" -v kw="$KEEP_WEEKLY" -v km="$KEEP_MONTHLY" '
    BEGIN {
      prefix = role "-backup-"
      plen = length(prefix)
      epoch = mktime("1970 01 01 12 00 00")
    }
    {
      ts = substr($0, plen + 1, 16)
      if (length(ts) != 16 || substr(ts, 9, 1) != "T" || substr(ts, 16, 1) != "Z") next
      y = substr(ts, 1, 4) + 0; mo = substr(ts, 5, 2) + 0; d = substr(ts, 7, 2) + 0
      days = int((mktime(sprintf("%04d %02d %02d 12 00 00", y, mo, d)) - epoch) / 86400)
      ++n
      f[n] = $0
      day[n] = substr(ts, 1, 8)
      week[n] = int((days + 3) / 7)
      month[n] = substr(ts, 1, 6)
    }
    END {
      for (i = 1; i <= n; i++) { wday[day[i]] = week[i]; mday[day[i]] = month[i] }
      # Tier 1: newest KEEP_DAILY distinct days.
      for (i = 1; i <= n && nd < kd; i++)
        if (!(day[i] in sd)) { sd[day[i]] = 1; kept[f[i]] = 1; nd++; od = day[i] }
      cut_week = (od == "") ? 0 : wday[od]
      # Tier 2: newest zip of each distinct week older than the oldest daily.
      for (i = 1; i <= n && nw < kw; i++)
        if (week[i] < cut_week && !(week[i] in sw)) {
          sw[week[i]] = 1; kept[f[i]] = 1; nw++; om = month[i]
        }
      # Tier 3: newest zip of each distinct month older than the oldest weekly
      # (or the oldest daily, if no weeklies were kept).
      cut_month = (om != "") ? om : (od == "" ? "" : mday[od])
      for (i = 1; cut_month != "" && i <= n && nm < km; i++)
        if (month[i] < cut_month && !(month[i] in sm)) {
          sm[month[i]] = 1; kept[f[i]] = 1; nm++
        }
      for (i = 1; i <= n; i++) if (!(f[i] in kept)) print f[i]
    }' | while IFS= read -r victim; do
      rm -f "$DEST_DIR/$victim"
      log "pruned old backup: $victim"
    done
}

# ---------------------------------------------------------------------------
# Scheduling
# ---------------------------------------------------------------------------

# Seconds until the next BACKUP_AT. $1 is the minimum seconds into the future
# (0 at startup; pass 3600 after a completed run so the fall-back-DST hour
# cannot trigger a second run one hour later).
seconds_until_next_run() {
  min_gap=${1:-0}
  now=$(date +%s)
  target=$(date -d "$(date +%F) $BACKUP_AT:00" +%s)
  if [ "$target" -lt $((now + min_gap)) ]; then
    target=$((target + 86400))
  fi
  echo $((target - now))
}

main() {
  if [ "${BACKUP_NOW:-0}" = 1 ]; then
    run_backup
    prune_backups
    return 0
  fi
  case ${1:-} in
    --now) run_backup; prune_backups; return 0 ;;
    -h | --help) usage; return 0 ;;
    "") ;;
    *) usage >&2; return 2 ;;
  esac

  log "backup scheduler started (role=$ROLE dest=$DEST_DIR at=$BACKUP_AT keep=${KEEP_DAILY}d/${KEEP_WEEKLY}w/${KEEP_MONTHLY}m)"
  gap=0
  while :; do
    wait=$(seconds_until_next_run "$gap")
    log "next backup at $BACKUP_AT (sleeping ${wait}s)"
    sleep "$wait"
    if run_backup; then
      prune_backups
    else
      log "ERROR: backup run failed" >&2
    fi
    # A completed run must be at least an hour in the past before the next
    # target fires, so the fall-back-DST hour cannot cause a double run.
    gap=3600
  done
}

# Tests source this script for its functions; the guard keeps main() quiet.
if [ -z "${BACKUP_SOURCE_ONLY:-}" ]; then
  main "$@"
fi
