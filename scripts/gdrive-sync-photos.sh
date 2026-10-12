#!/usr/bin/env bash
# Two-way sync of the Photos subtree only (local <-> Google Drive), every minute.
# Own bisync state (separate path pair: .../Google Drive/Photos <-> google drive:Photos).
# Shares a lock with the hourly whole-drive sync so the two never overlap.
#
# Live copy: ~/.local/bin/gdrive-sync-photos.sh (desktop). Remote name/paths are
# machine-specific; see systemd/user/README.md in this repo for the full setup.
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
    exit 0
fi

# Non-blocking: if the whole-drive job holds the lock, skip this tick.
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

"$RCLONE" bisync "$LOCAL_DIR" "$REMOTE" \
    --drive-import-formats docx,xlsx,pptx \
    --filters-file "$FILTERS_FILE" \
    --log-file "$LOG_FILE" \
    --log-level INFO \
    "$@"

# Record the last successful sync for the staleness alarm.
if [ $? -eq 0 ]; then
    date +%s > "${LOG_DIR}/last-sync-photos.ok"
fi
