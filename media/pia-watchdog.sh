#!/usr/bin/env bash
# pia-watchdog: detect PIA port-forwarding failure in the qbittorrent container,
# probe candidate regions for a live port-forward service, and re-pin the region.
#
# Why this exists: PIA's port-forward API (:19999 on each VPN server) is being
# disabled server-by-server without documentation. The regions JSON's
# port_forward flags drift from reality, so the only reliable check is to
# probe the service itself. This script:
#   1. counts recent "Signature and Payload retrieval failed!" log lines
#   2. if the failure threshold is met, probes candidate regions' WG servers
#   3. re-pins VPN_PIA_PREFERRED_REGION to the first region that answers,
#      recreates the container, and verifies the port actually lands in qBittorrent
#
# Usage:
#   pia-watchdog.sh            # main loop: detect -> probe -> pin
#   pia-watchdog.sh probe      # show candidate regions and probe results
#   pia-watchdog.sh pin <region>  # force pin + verify a specific region
#
# Installed via cron (see pia-watchdog.md).

set -u

CONTAINER="qbittorrent"
COMPOSE_DIR="/home/wbw/docker_files/media"
YML="$COMPOSE_DIR/qbittorrent.yml"
REGIONS_JSON="/media/qbittorrent/config/wireguard/pia-regions.json"
LOG_TAG="pia-watchdog"
LOCKFILE="/tmp/pia-watchdog.lock"

# Ordered preference: North America first (matches operator location),
# then the community-maintained European PF gateways. Each is still
# probed at runtime; static order is only a preference.
CANDIDATE_ORDER=(
    ca_vancouver
    ca
    nl_amsterdam
    swiss
    czech
    ro
    sweden
    sweden_2
    de-frankfurt
    es-valencia
    tr
    lt
)

FAIL_WINDOW="6m"      # look this far back in container logs
FAIL_THRESHOLD=3      # retries are ~60s apart, so 3 = ~3+ minutes of failing
GRACE_SECONDS=360     # ignore the container right after a start/recreate
PIN_VERIFY_TIMEOUT=120

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; logger -t "$LOG_TAG" -- "$*" 2>/dev/null || true; }

exec 9>"$LOCKFILE"
flock -n 9 || { log "another run holds the lock, exiting"; exit 0; }

container_started_seconds() {
    local started now
    started=$(docker inspect "$CONTAINER" --format '{{.State.StartedAt}}' 2>/dev/null) || { echo 999999; return; }
    now=$(date +%s)
    echo $(( now - $(date -d "$started" +%s) ))
}

current_region() {
    docker exec "$CONTAINER" printenv VPN_PIA_PREFERRED_REGION 2>/dev/null || echo ""
}

region_wg_ips() {  # up to 3 WireGuard server IPs for a region (space-separated)
    python3 - "$1" "$REGIONS_JSON" <<'PY'
import json, sys
rid, path = sys.argv[1], sys.argv[2]
try:
    regions = json.load(open(path))["regions"]
except Exception:
    sys.exit(0)
for r in regions:
    if r.get("id") == rid:
        if not r.get("port_forward"):
            sys.exit(0)
        ips = [s["ip"] for s in r.get("servers", {}).get("wg", []) if s.get("ip")][:3]
        if ips:
            print(" ".join(ips))
        break
PY
}

probe_ip() {  # port-forward service answers on :19999? retried: single-connection results are noisy
    local ip="$1" attempt
    for attempt in 1 2 3; do
        if docker exec "$CONTAINER" nc -w 4 -z "$ip" 19999 >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

probe_region() {  # any of the region's tested servers answers?
    local ips="$1" ip
    for ip in $ips; do
        if probe_ip "$ip"; then
            return 0
        fi
    done
    return 1
}

candidates_available() {  # candidate regions minus the currently pinned one
    local current
    current=$(current_region)
    local c out=()
    for c in "${CANDIDATE_ORDER[@]}"; do
        [ "$c" = "$current" ] && continue
        # keep only regions the metadata still flags as PF-capable
        if grep -q "\"id\": *\"$c\"" "$REGIONS_JSON" 2>/dev/null; then
            out+=("$c")
        fi
    done
    printf '%s\n' "${out[@]}"
}

pin_region() {  # set the region in the compose file, recreate, verify the port lands
    local region="$1"
    sed -i "s|VPN_PIA_PREFERRED_REGION=.*#|VPN_PIA_PREFERRED_REGION=${region} #|" "$YML"
    if ! grep -q "VPN_PIA_PREFERRED_REGION=${region} #" "$YML"; then
        log "ERROR: failed to update $YML for region $region"
        return 1
    fi
    log "re-pinning region to [$region], recreating $CONTAINER ..."
    (cd "$COMPOSE_DIR" && docker compose up -d "$CONTAINER" >/dev/null 2>&1) || { log "ERROR: compose up failed"; return 1; }
    local waited=0
    while [ "$waited" -lt "$PIN_VERIFY_TIMEOUT" ]; do
        sleep 10; waited=$((waited + 10))
        if docker logs "$CONTAINER" --since 3m 2>&1 | grep -q "Updated forwarded port"; then
            local port
            port=$(docker logs "$CONTAINER" --since 3m 2>&1 | grep -oE "Updated forwarded port to \[[0-9]+\]" | tail -1)
            log "SUCCESS: region [$region] forwarded port bound: $port"
            return 0
        fi
    done
    log "region [$region] did not produce a forwarded port within ${PIN_VERIFY_TIMEOUT}s"
    return 1
}

cmd_probe() {
    echo "candidate regions (order = preference):"
    while read -r c; do
        [ -n "$c" ] || continue
        ips=$(region_wg_ips "$c")
        if [ -z "$ips" ]; then echo "  $c: no WG ip / metadata says no PF, skipped"; continue; fi
        if probe_region "$ips"; then echo "  $c ($ips): OPEN"; else echo "  $c ($ips): closed"; fi
    done < <(candidates_available)
}

cmd_pin() {
    local region="$1"
    [ -n "$region" ] || { echo "usage: pia-watchdog.sh pin <region>"; exit 2; }
    pin_region "$region"
}

main() {
    # startup grace: a fresh container may log a few transient failures
    local age
    age=$(container_started_seconds)
    if [ "$age" -lt "$GRACE_SECONDS" ]; then
        log "container started ${age}s ago (< ${GRACE_SECONDS}s grace), skipping check"
        exit 0
    fi

    local failures
    failures=$(docker logs "$CONTAINER" --since "$FAIL_WINDOW" 2>&1 | grep -c "Signature and Payload retrieval failed" || true)
    if [ "${failures:-0}" -lt "$FAIL_THRESHOLD" ]; then
        log "PF healthy ($failures signature failures in $FAIL_WINDOW, threshold $FAIL_THRESHOLD)"
        exit 0
    fi

    local current
    current=$(current_region)
    log "PF DOWN detected: $failures signature failures in $FAIL_WINDOW (pinned region: ${current:-<random>})"
    log "probing candidate regions for a live port-forward service ..."

    local open=()
    while read -r c; do
        [ -n "$c" ] || continue
        local ips
        ips=$(region_wg_ips "$c")
        [ -z "$ips" ] && continue
        if probe_region "$ips"; then
            open+=("$c")
            log "  $c ($ips): OPEN"
        else
            log "  $c ($ips): closed"
        fi
    done < <(candidates_available)

    if [ "${#open[@]}" -eq 0 ]; then
        log "ALERT: no candidate region answers the port-forward service. PIA may have withdrawn the feature. qBittorrent continues in passive (outbound-only) mode."
        exit 1
    fi

    for c in "${open[@]}"; do
        if pin_region "$c"; then
            exit 0
        fi
    done

    log "ALERT: all OPEN candidates failed to produce a forwarded port. Leaving last-pinned region in place; will retry next run."
    exit 1
}

case "${1:-}" in
    probe) cmd_probe ;;
    pin)   shift; cmd_pin "${1:-}" ;;
    "")    main ;;
    *)     echo "usage: pia-watchdog.sh [probe|pin <region>]"; exit 2 ;;
esac
