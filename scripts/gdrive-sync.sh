#!/usr/bin/env bash
# Two-way sync: local "Slowby/Google Drive" folder <-> Google Drive (rclone remote "google drive:").
# Whole-tree pass, run hourly (see gdrive-sync.timer). Photos-only runs every minute
# via gdrive-sync-photos.sh; both share a flock so they never overlap.
# Live copy: ~/.local/bin/gdrive-sync.sh (desktop); repo edits do not install themselves.
# Requires an initial `rclone bisync --resync` per path pair to establish the baseline.
#
# Live copy: ~/.local/bin/gdrive-sync.sh (desktop). Remote name/paths are
# machine-specific; see systemd/user/README.md in this repo for the full setup.
# Marker path is also read (and seeded) by gdrive-sync-alert.sh; rename in both places together.
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
    --max-lock 2m --resilient --recover \
    "$@"

# set -e already guarantees this only runs on bisync success; the marker feeds the staleness alarm.
date +%s > "${LOG_DIR}/last-sync.ok"
