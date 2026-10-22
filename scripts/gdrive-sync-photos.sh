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

"$RCLONE" bisync "$LOCAL_DIR" "$REMOTE" \
    --drive-import-formats docx,xlsx,pptx \
    --filters-file "$FILTERS_FILE" \
    --log-file "$LOG_FILE" \
    --log-level INFO \
    --max-lock 2m --resilient --recover \
    "$@"

# set -e already guarantees this only runs on bisync success; the marker feeds the staleness alarm.
date +%s > "${LOG_DIR}/last-sync-photos.ok"
