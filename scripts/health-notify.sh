#!/bin/sh
set -eu

STATE_DIR=${STATE_DIR:-/state}
POLL_INTERVAL=${POLL_INTERVAL:-60}
STALL_SECONDS=${STALL_SECONDS:-3600}
DISK_FREE_THRESHOLD=${DISK_FREE_THRESHOLD:-25}
CERT_WARN_DAYS=${CERT_WARN_DAYS:-30}
CERT_HOST=${CERT_HOST:-}
UNPACKERR_LOG=${UNPACKERR_LOG:-/unpackerr/unpackerr.log}

WATCH_CONTAINERS="plex ombi sonarr radarr prowlarr whisparr flaresolverr sabnzbd unpackerr qbittorrent frigate postgres autoheal stash immich-server immich-machine-learning immich-postgres immich-redis"

mkdir -p "$STATE_DIR"

send() {
  curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=$1" >/dev/null 2>&1 || true
}

read_state() {
  if [ -f "$STATE_DIR/$1" ]; then
    cat "$STATE_DIR/$1"
  fi
}

write_state() {
  printf '%s' "$2" > "$STATE_DIR/$1"
}

safe_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

health_detail() {
  name=$1
  probe=$(docker inspect "$name" --format '{{json .State.Health.Log}}' 2>/dev/null |
    jq -r '.[-1] | "exit=\(.ExitCode), output=\(.Output // "(no output)")"' 2>/dev/null || true)
  logs=$(docker logs --tail 15 "$name" 2>&1 | tr -d '\r' | tail -c 800 || true)
  detail="Health check: ${probe:-no health-check output recorded}"
  if [ -n "$logs" ]; then
    detail="$detail
Last logs:
$logs"
  fi
  printf '%s' "$detail" | cut -c1-2000
}

watch_events() {
  docker events --filter type=container \
    --format '{{.Action}}|{{.Actor.Attributes.name}}|{{.Actor.Attributes.exitCode}}|{{.Actor.Attributes.signal}}' |
  while IFS='|' read -r action name exit_code signal; do
    case " $WATCH_CONTAINERS " in
      *" $name "*) ;;
      *) continue ;;
    esac

    case "$action" in
      oom)
        send "🚨 $name was OOM-killed."
        ;;
      die)
        write_state "down.$name" "1"
        send "🚨 $name stopped (exit=${exit_code:-unknown}${signal:+, signal=$signal})."
        ;;
      restart)
        send "🔄 $name restarted."
        ;;
      start)
        if [ -f "$STATE_DIR/down.$name" ]; then
          send "✅ $name started again."
          rm -f "$STATE_DIR/down.$name"
        fi
        ;;
      health_status:*)
        status=$(printf '%s' "$action" | sed 's/^health_status: *//')
        previous=$(read_state "health.$name")
        if [ "$status" = "unhealthy" ] && [ "$previous" != "unhealthy" ]; then
          send "⚠️ $name is unhealthy.
$(health_detail "$name")"
        elif [ "$status" = "healthy" ] && [ "$previous" = "unhealthy" ]; then
          send "✅ $name is healthy again."
        fi
        write_state "health.$name" "$status"
        ;;
    esac
  done
}

check_disk() {
  df -P /data /sab-config 2>/dev/null |
    awk 'NR > 1 && !seen[$1]++ {gsub("%", "", $5); print $1 "|" $5 "|" $6}' |
  while IFS='|' read -r device used mount; do
    [ -n "$device" ] || continue
    free=$((100 - used))
    key=$(safe_name "$device")
    previous=$(read_state "disk.$key")
    if [ "$free" -lt "$DISK_FREE_THRESHOLD" ]; then
      if [ "$previous" != "low" ]; then
        send "⚠️ Disk space is low on $mount: ${free}% free (${used}% used)."
      fi
      write_state "disk.$key" "low"
    else
      if [ "$previous" = "low" ]; then
        send "✅ Disk space recovered on $mount: ${free}% free."
      fi
      write_state "disk.$key" "ok"
    fi
  done
}

check_qbit() {
  payload=$(docker exec qbittorrent curl -fsS --max-time 15 \
    'http://127.0.0.1:8080/api/v2/torrents/info?filter=all' 2>/dev/null || true)
  [ -n "$payload" ] || return 0

  cutoff=$(($(date +%s) - STALL_SECONDS))
  count=$(printf '%s' "$payload" |
    jq --argjson cutoff "$cutoff" '[.[] | select((.state == "stalledDL" or .state == "metaDL") and .progress < 1 and (.last_activity == 0 or .last_activity < $cutoff))] | length')
  summary=$(printf '%s' "$payload" |
    jq -r --argjson cutoff "$cutoff" '[.[] | select((.state == "stalledDL" or .state == "metaDL") and .progress < 1 and (.last_activity == 0 or .last_activity < $cutoff))] | sort_by(.added_on) | map("\(.name) [\((.progress * 100)|floor)%]") | join("\n")')
  fingerprint=$(printf '%s' "$summary" | cksum | awk '{print $1}')
  previous=$(read_state "qbit.fingerprint")
  was_active=$(read_state "qbit.active")

  if [ "$count" -gt 0 ]; then
    if [ "$fingerprint" != "$previous" ] || [ "$was_active" != "1" ]; then
      send "⚠️ qBittorrent has $count torrent(s) stalled for over 1 hour:
$summary"
    fi
    write_state "qbit.active" "1"
  elif [ "$was_active" = "1" ]; then
    send "✅ qBittorrent's stalled queue cleared."
    write_state "qbit.active" "0"
  else
    write_state "qbit.active" "0"
  fi
  write_state "qbit.fingerprint" "$fingerprint"
}

check_sab() {
  [ -n "${SAB_API_KEY:-}" ] || return 0
  payload=$(curl -fsS --max-time 15 \
    "http://sabnzbd:9090/api?mode=queue&output=json&apikey=${SAB_API_KEY}" 2>/dev/null || true)
  [ -n "$payload" ] || return 0

  active=$(printf '%s' "$payload" |
    jq -c '[.queue.slots[]? | select(.status == "Downloading" or .status == "Fetching") | {id: .nzo_id, name: .filename, left: .mbleft, status: .status}] | sort_by(.id)')
  count=$(printf '%s' "$active" | jq 'length')
  signature=$(printf '%s' "$active" | cksum | awk '{print $1}')
  previous=$(read_state "sab.signature")
  since=$(read_state "sab.since")
  alerted=$(read_state "sab.alerted")
  now=$(date +%s)

  case "$since" in
    ''|*[!0-9]*) since=$now ;;
  esac

  if [ "$count" -eq 0 ]; then
    if [ "$alerted" = "1" ]; then
      send "✅ SABnzbd is no longer stalled."
    fi
    write_state "sab.signature" "$signature"
    write_state "sab.since" "$now"
    write_state "sab.alerted" "0"
    return 0
  fi

  if [ "$signature" != "$previous" ]; then
    if [ "$alerted" = "1" ]; then
      send "✅ SABnzbd queue activity resumed."
    fi
    write_state "sab.signature" "$signature"
    write_state "sab.since" "$now"
    write_state "sab.alerted" "0"
  elif [ $((now - since)) -ge "$STALL_SECONDS" ] && [ "$alerted" != "1" ]; then
    summary=$(printf '%s' "$active" | jq -r 'map(.name) | join("\n")')
    send "⚠️ SABnzbd has had no queue progress for over 1 hour:
$summary"
    write_state "sab.alerted" "1"
  fi
}

check_arr() {
  label=$1
  base_url=$2
  api_key=$3
  last_file=$4

  [ -n "$api_key" ] || return 0
  payload=$(curl -fsS --max-time 15 \
    -H "X-Api-Key: $api_key" \
    "$base_url/api/v3/history?page=1&pageSize=50&sortKey=date&sortDirection=descending" 2>/dev/null || true)
  [ -n "$payload" ] || return 0

  maximum=$(printf '%s' "$payload" | jq '[.records[]?.id // 0] | max // 0')
  previous=$(read_state "$last_file")
  case "$previous" in
    ''|*[!0-9]*) write_state "$last_file" "$maximum"; return 0 ;;
  esac

  if [ "$maximum" -gt "$previous" ]; then
    printf '%s' "$payload" |
      jq -r --argjson previous "$previous" '
        .records[]?
        | select(.id > $previous and ((.eventType // "") | test("(?i)(downloadfailed|importfailed)")))
        | "\(.id)|\(.eventType)|\(.series.title // .movie.title // .sourceTitle // "unknown")|\(.data.message // .message // "")"
      ' |
    head -n 8 |
    while IFS='|' read -r id event_type title message; do
      [ -n "$id" ] || continue
      send "⚠️ $label $event_type:
$title${message:+
$message}"
    done
    write_state "$last_file" "$maximum"
  fi
}

check_unpackerr() {
  [ -f "$UNPACKERR_LOG" ] || return 0
  line=$(grep -Ei 'error|failed|crc|unavailable|timeout|article' "$UNPACKERR_LOG" | tail -n 1 || true)
  [ -n "$line" ] || return 0
  line=$(printf '%s' "$line" | cut -c1-700)
  fingerprint=$(printf '%s' "$line" | cksum | awk '{print $1}')
  previous=$(read_state "unpackerr.fingerprint")
  if [ -n "$previous" ] && [ "$fingerprint" != "$previous" ]; then
    send "⚠️ Unpackerr reported an extraction/download error:
$line"
  fi
  write_state "unpackerr.fingerprint" "$fingerprint"
}

check_http() {
  label=$1
  url=$2
  failures_file="http.$label.failures"
  status_file="http.$label.status"

  if curl -fsS --max-time 10 "$url" >/dev/null 2>&1; then
    previous=$(read_state "$status_file")
    if [ "$previous" = "down" ]; then
      send "✅ $label is responding again."
    fi
    write_state "$status_file" "up"
    write_state "$failures_file" "0"
  else
    failures=$(read_state "$failures_file")
    case "$failures" in
      ''|*[!0-9]*) failures=0 ;;
    esac
    failures=$((failures + 1))
    write_state "$failures_file" "$failures"
    if [ "$failures" -ge 3 ] && [ "$(read_state "$status_file")" != "down" ]; then
      send "⚠️ $label is not responding after 3 checks."
      write_state "$status_file" "down"
    fi
  fi
}

check_certificate() {
  [ -n "$CERT_HOST" ] || return 0
  cert_file="$STATE_DIR/certificate.pem"
  if printf '\n' |
    openssl s_client -servername "$CERT_HOST" -connect "$CERT_HOST:443" 2>/dev/null |
    openssl x509 -out "$cert_file" 2>/dev/null; then
    expiry=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null || true)
    if printf '%s' "$expiry" | grep -q '^notAfter=' &&
      openssl x509 -in "$cert_file" -checkend "$((CERT_WARN_DAYS * 86400))" -noout >/dev/null 2>&1; then
      status=ok
    elif [ -n "$expiry" ]; then
      status=warning
    else
      status=failed
    fi
  else
    status=failed
    expiry=
  fi

  previous=$(read_state "certificate.status")
  if [ "$status" != "$previous" ]; then
    case "$status" in
      warning) send "⚠️ TLS certificate for $CERT_HOST expires within $CERT_WARN_DAYS days ($expiry)." ;;
      failed) send "⚠️ Could not verify the TLS certificate for $CERT_HOST." ;;
      ok)
        [ "$previous" = "warning" ] || [ "$previous" = "failed" ] &&
          send "✅ TLS certificate for $CERT_HOST is valid again."
        ;;
    esac
    write_state "certificate.status" "$status"
  fi
  rm -f "$cert_file"
}

watch_events &
EVENT_PID=$!
trap 'kill "$EVENT_PID" 2>/dev/null || true' EXIT INT TERM

echo "Monitoring Docker events, disk space, queues, Arr history, Unpackerr, HTTP services, and TLS."

while :; do
  check_disk
  check_arr "Sonarr" "http://sonarr:8989" "${SONARR_API_KEY:-}" "arr.sonarr.last"
  check_arr "Radarr" "http://radarr:7878" "${RADARR_API_KEY:-}" "arr.radarr.last"
  check_unpackerr
  check_http "Ombi" "http://ombi:3579/ombi/"
  check_http "Plex" "http://plex:32400/identity"
  check_http "Sonarr" "http://sonarr:8989/ping"
  check_http "Radarr" "http://radarr:7878/ping"
  check_http "Prowlarr" "http://prowlarr:9696/ping"
  check_http "Whisparr" "http://whisparr:6969/ping"
  check_http "FlareSolverr" "http://flaresolverr:8191/"
  check_http "Stash" "http://stash:9999/"
  check_http "Frigate" "http://frigate:5000/api/version"
  check_http "Immich" "http://immich-server:2283/api/server/ping"
  check_http "ImmichML" "http://immich-machine-learning:3003/ping"
  check_certificate
  sleep "$POLL_INTERVAL"
done
