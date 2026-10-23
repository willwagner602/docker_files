#!/usr/bin/env bash
# Two-way sync of the Photos subtree only (local <-> Google Drive), every minute.
# Own bisync state (separate path pair: .../Google Drive/Photos <-> google drive:Photos).
# Shares a lock with the every-10-minutes whole-tree sync so the two never overlap.
# Marker path is also read (and seeded) by gdrive-sync-alert.sh; rename in both places together.
#
# Live copy: ~/.local/bin/gdrive-sync-photos.sh (desktop). Remote name/paths are
# machine-specific; see systemd/user/README.md in this repo for the full setup.
# Repo edits do not install themselves; this is a desktop-local copy.
set -euo pipefail

MOUNT_POINT="/run/media/wbw/Slowby"
LOCAL_DIR="${MOUNT_POINT}/Google Drive/Photos"
REMOTE="google drive:Photos"
FILTERS_FILE="${HOME}/.config/rclone/gdrive-sync-filters.txt"
LOG_DIR="${HOME}/.local/state/gdrive-sync"
LOG_FILE="${LOG_DIR}/photos-sync.log"
RCLONE="${HOME}/.local/bin/rclone"
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/gdrive-sync.lock"

mkdir -p "$LOG_DIR"

if ! mountpoint -q "$MOUNT_POINT"; then
    echo "$(date -Is) Slowby not mounted, skipping photos sync." >> "$LOG_FILE"
    exit 0
fi

# Non-blocking: if the whole-drive job holds the lock, skip this tick.
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

# Rotate the rclone log at 200 MB (keep one previous generation) so the
# per-minute log cannot grow indefinitely and contribute to home disk
# exhaustion. Implemented inline because /etc/logrotate.d changes need
# root on this desktop.
LOG_MAX_BYTES=$((200 * 1024 * 1024))
logsize=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
if [ "$logsize" -gt "$LOG_MAX_BYTES" ]; then
    mv -f "$LOG_FILE" "${LOG_FILE}.1"
    gzip -9 "${LOG_FILE}.1" 2>/dev/null &
fi

# Self-heal a stale bisync lock: safe only when no bisync process is
# running for this path pair. A run killed before completion (e.g. by
# disk exhaustion) leaves a lock rclone refuses to clear on its own
# ('--max-lock' ignores zero-byte locks with empty expiry).
# Match only real rclone processes (pgrep -x) and inspect /proc cmdline
# per pid; plain pgrep -f can false-positive on unrelated processes
# whose command line merely contains the pattern text.
bisync_running() { # $1 = substring of the rclone cmdline to match
    local p
    for p in $(pgrep -x rclone || true); do
        tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -qF -- "$1" && return 0
    done
    return 1
}
BISYNC_STATE_DIR="${HOME}/.cache/rclone/bisync"
LOCK_PATTERN="run_media_wbw_Slowby_Google_Drive_Photos..google_drive_Photos.lck"
if bisync_running 'Slowby/Google Drive/Photos'; then
    : # a Photos bisync is running; leave the lock alone
elif compgen -G "${BISYNC_STATE_DIR}/${LOCK_PATTERN}" >/dev/null; then
    # Only reclaim locks at least 5 minutes old so a live run's lock,
    # whose mtime updates as it renews, is never touched.
    for l in "${BISYNC_STATE_DIR}"/${LOCK_PATTERN}; do
        age=$(( $(date +%s) - $(stat -c %Y "$l") ))
        [ "$age" -ge 300 ] && rm -f "$l" && \
            echo "$(date -Is) Reclaimed stale bisync lock: $l" >> "$LOG_FILE"
    done
fi

# Refuse to run when home is nearly full: a disk-full condition makes
# rclone abort after creating a zero-byte lock, which wedges future runs.
AVAIL_KB=$(df -Pk "$HOME" | awk 'NR==2 {print $4}')
if [ "${AVAIL_KB:-0}" -lt 2097152 ]; then   # < 2 GiB free
    echo "$(date -Is) Home filesystem low on space (${AVAIL_KB} KiB free); skipping photos sync to avoid lock corruption." >> "$LOG_FILE"
    exit 0
fi

"$RCLONE" bisync "$LOCAL_DIR" "$REMOTE" \
    --drive-import-formats docx,xlsx,pptx \
    --filters-file "$FILTERS_FILE" \
    --log-file "$LOG_FILE" \
    --log-level INFO \
    --max-lock 2m --resilient --recover \
    "$@"

# set -e already guarantees this only runs on bisync success; the marker feeds the staleness alarm.
date +%s > "${LOG_DIR}/last-sync-photos.ok"
