#!/usr/bin/env bash
# Two-way sync: local "Slowby/Google Drive" folder <-> Google Drive (rclone remote "google drive:").
# Whole-drive pass, run hourly (see gdrive-sync.timer). Photos-only runs every minute
# via gdrive-sync-photos.sh; both share a flock so they never overlap.
# Requires an initial `rclone bisync --resync` per path pair to establish the baseline.
#
# Live copy: ~/.local/bin/gdrive-sync.sh (desktop). Remote name/paths are
# machine-specific; see systemd/user/README.md in this repo for the full setup.
set -euo pipefail

MOUNT_POINT="/run/media/wbw/Slowby"
LOCAL_DIR="${MOUNT_POINT}/Google Drive"
REMOTE="google drive:"
FILTERS_FILE="${HOME}/.config/rclone/gdrive-sync-filters.txt"
LOG_DIR="${HOME}/.local/state/gdrive-sync"
LOG_FILE="${LOG_DIR}/sync.log"
RCLONE="${HOME}/.local/bin/rclone"
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/gdrive-sync.lock"

mkdir -p "$LOG_DIR"

if ! mountpoint -q "$MOUNT_POINT"; then
    echo "$(date -Is) Slowby not mounted, skipping." >> "$LOG_FILE"
    exit 0
fi

# Shared lock with the photos job: wait up to 4 min (photos runs are ~35s), then skip.
exec 9>"$LOCK_FILE"
if ! flock -w 240 9; then
    echo "$(date -Is) Lock busy, skipping whole-drive sync." >> "$LOG_FILE"
    exit 0
fi

"$RCLONE" bisync "$LOCAL_DIR" "$REMOTE" \
    --drive-import-formats docx,xlsx,pptx \
    --filters-file "$FILTERS_FILE" \
    --log-file "$LOG_FILE" \
    --log-level INFO \
    "$@"

# Record the last successful sync for the staleness alarm.
if [ $? -eq 0 ]; then
    date +%s > "${LOG_DIR}/last-sync.ok"
fi
