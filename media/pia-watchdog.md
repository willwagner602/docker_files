# PIA Port-Forward Watchdog

Automates the "probe-first-then-pin" recovery for qBittorrent's PIA port
forwarding. Background: PIA's port-forward service (`:19999/getSignature` on
each VPN server) is being disabled server-by-server without documentation or
announcement. PIA's own regions metadata (`port_forward` flags) has drifted
from reality, so the only reliable test is to probe the service itself.

## What the script does

1. **Detect** — counts `Signature and Payload retrieval failed!` lines in the
   qBittorrent container logs over the last 6 minutes. 3+ (retries are ~60 s
   apart) = port forwarding is down. A fresh container gets a 6-minute grace
   period before checking.
2. **Probe** — for each candidate region (below), reads the server's WireGuard
   IP from `/media/qbittorrent/config/wireguard/pia-regions.json` and tests
   whether `:19999` answers, through the tunnel. A connection that opens means
   the service is alive on that server. Metadata flags are ignored for this
   decision.
3. **Pin** — writes the first region that answers into `qbittorrent.yml`
   (`VPN_PIA_PREFERRED_REGION`), recreates the container, and verifies the log
   shows `Updated forwarded port to [N]` within 2 minutes. If a candidate
   fails verification, it falls through to the next.
4. **Report** — logs to syslog (`journalctl -t pia-watchdog`) and stderr. If
   no region answers at all, it alerts and exits 1; qBittorrent continues in
   passive (outbound-only) mode, which still downloads and partially seeds.

Candidate order (preference): `ca_vancouver, ca, nl_amsterdam, swiss, czech,
ro, sweden, sweden_2, de-frankfurt, es-valencia, tr, lt`. The currently pinned
region is always skipped (it is what just failed).

## Install

Cron entry (30-minute cadence):

```
*/30 * * * * /home/wbw/docker_files/media/pia-watchdog.sh >> $HOME/.local/state/pia-watchdog.log 2>&1
```

Apply with: `(crontab -l 2>/dev/null; echo '<line above>') | crontab -`

## Manual use

```
./pia-watchdog.sh probe             # list candidates + live/dead status
./pia-watchdog.sh pin ca_vancouver  # force pin a region + verify
./pia-watchdog.sh                   # full detect -> probe -> pin cycle
```

## Files touched

- `qbittorrent.yml` — the `VPN_PIA_PREFERRED_REGION` line (and nothing else).
  The compose project directory and config path must stay correct; the script
  recreates the container on a region change (~90 s; torrents resume
  automatically).

## Known limits

- The probe only validates that the service answers; if PIA withdraws the
  feature everywhere, the script alerts and exits 1 without a fix. At that
  point the options are switching to a provider that still forwards ports
  (ProtonVPN via NAT-PMP, AirVPN per-port assignment) or a gluetun-based setup.
- Changing the candidate order or adding regions: edit `CANDIDATE_ORDER` in
  the script. Regions flagged `port_forward: false` in the metadata are
  skipped automatically.
