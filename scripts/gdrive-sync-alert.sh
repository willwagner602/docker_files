#!/usr/bin/env bash
# Staleness alarm for gdrive-sync.
# Alarms name the job ("Google Drive" = whole tree, which covers Photos;
# "Google Drive Photos" = photos pair only); markers are last-sync.ok and
# last-sync-photos.ok. This watcher
# checks both every minute and pops a critical notification + sound only
# when BOTH conditions hold:
#   - at least one job has not succeeded in at least STALE_HOURS, and
#   - the local time is inside the alarm window (10:00 <= t < 20:00).
# While the condition persists it re-notifies at most once per REPEAT_HOURS,
# naming whichever job(s) are stale.
#
# Live copy: ~/.local/bin/gdrive-sync-alert.sh (desktop). See
# systemd/user/README.md in this repo for the full setup.
set -u

LOG_DIR="${HOME}/.local/state/gdrive-sync"
OK_WHOLE="${LOG_DIR}/last-sync.ok"
OK_PHOTOS="${LOG_DIR}/last-sync-photos.ok"
ALARM_TS_FILE="${LOG_DIR}/last-alarm.sent"

STALE_HOURS=6
WINDOW_START=10   # alarm window start hour, local time (inclusive)
WINDOW_END=20     # alarm window end hour, local time (exclusive)
CHECK_INTERVAL=60
REPEAT_HOURS=1

mkdir -p "$LOG_DIR"

# Seed missing trackers on first run so nothing alarms immediately after
# a fresh install or wipe (trust-first default).
now=$(date +%s)
[ -f "$OK_WHOLE" ] || date +%s > "$OK_WHOLE"
[ -f "$OK_PHOTOS" ] || date +%s > "$OK_PHOTOS"

# Copy-then-read limits damage from a torn write; the trust-first fallback
# (missing/garbage => now) is the actual guarantee against false alarms.
read_ts() {
    tmp=$(mktemp) || { echo "$now"; return; }
    if cp "$1" "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        val=$(tr -dc '0-9\n' < "$tmp" | head -n1)
        case "$val" in
            ''|*[!0-9]*) echo "$now" ;;
            *) echo "$val" ;;
        esac
    else
        echo "$now"
    fi
    rm -f "$tmp"
}

notify() {
    names="$1"; earliest_ts="$2"
    if [ "${GDRIVE_SYNC_ALERT_DRY:-0}" = "1" ]; then
        echo "(dry-run would alarm) [$names]: stale $(( ($(date +%s) - earliest_ts) / 3600 )) h"
        return
    fi
    age_h=$(( ($(date +%s) - earliest_ts) / 3600 ))
    echo "$(date -Is) alarm [$names]: stale ${age_h} h"
    notify-send -u critical -a "gdrive-sync" "Drive sync alarm ($names)" \
        "No successful sync for ${age_h} h. Check: systemctl --user list-timers 'gdrive-sync*' ; logs in ~/.local/state/gdrive-sync/" \
        2>>"${LOG_DIR}/alert.err" \
        || echo "$(date -Is) notify-send failed (no desktop session?)" >&2
    paplay /usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga 2>/dev/null || true
}

while true; do
    now=$(date +%s)
    hour=$(date +%H); hour=$((10#$hour))
    if [ $(( hour >= WINDOW_START && hour < WINDOW_END )) -eq 1 ]; then
        whole_ts=$(read_ts "$OK_WHOLE")
        photos_ts=$(read_ts "$OK_PHOTOS")
        stale_names=""
        earliest="$now"
        if [ $(( now - whole_ts >= STALE_HOURS * 3600 )) -eq 1 ]; then
            # Whole tree covers the Photos subtree too, so when it's stale
            # the whole tree name is enough on its own.
            stale_names="Google Drive"
            earliest=$whole_ts
        elif [ $(( now - photos_ts >= STALE_HOURS * 3600 )) -eq 1 ]; then
            stale_names="Google Drive Photos"
            earliest=$photos_ts
        fi
        if [ -n "$stale_names" ]; then
            last_alarm=$(cat "$ALARM_TS_FILE" 2>/dev/null || echo 0)
            case "$last_alarm" in ''|*[!0-9]*) last_alarm=0 ;; esac
            if [ $(( now - last_alarm >= REPEAT_HOURS * 3600 )) -eq 1 ]; then
                date +%s > "$ALARM_TS_FILE"
                notify "$stale_names" "$earliest"
            fi
        fi
    fi
    sleep "$CHECK_INTERVAL"
done
