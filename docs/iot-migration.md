# Strategy: Move All IoT Devices to a New VLAN in UniFi

> Revised 2026-10-22 from live controller state (USG-3P, Network Application
> 10.4.57, self-hosted linuxserver.io stack on `wbw-ha`). Best-practice
> research notes live in `~/iot-vlan-best-practices.md` — the 4-zone design
> below aligns with the consensus pattern documented there.

## § Design: Four zones

| # | Zone | VLAN | Subnet | Devices | Firewall posture |
|---|---|---|---|---|---|
| 1 | **Trusted** (existing `Default`) | untagged / 1 | 10.0.0.0/24 | `wbw-desktop`, `wbw-ha` (the "general" server), `wbw-media` (server), iPhone, Steam Deck, any other personal | Full internal + internet |
| 2 | **IoT HA** (rename `Secure`, VLAN 2) | 2 | 10.0.2.0/24 | Devices HA actively manages (Aqara hub, Tstat ×3, LG laundry, MyQ, esp32c3, wlan0) | → 10.0.0.16:8123/1883/device-ports + DNS + NTP + Internet. Deny all other LAN |
| 3 | **IoT Insecure** (new) | 3 (or 30) | 10.0.3.0/24 | Cloud-only clients (all Amazon plugs, KP115s, Envoy, adsb-monitor, BRW…) — and **default/unknown devices** | → DNS + NTP + Internet only. Deny all LAN, **except**: Trusted may initiate to `10.0.0.156` (adsb-monitor) and `10.0.0.234` (ff-18919) for web-UI access (explicit allow, 2026-10-22). Discovery via scoped mDNS reflector (`_airplay`, `_raop`, `_googlecast`) — see PR #56 |
| 4 | **IoT Secure** (new) | 4 (or 40) | 10.0.4.0/24 | Cameras/doorbell/voice hubs: Ring, Reolink (E1/Side/Garage wired), **BrosTrend outdoor-cam bridge**, Alexa; **note**: Living-Room Apple TV placed Zone 3 for cast/AirPlay reflection (2026-10-22) | → Trusted-only, per-IP camera permits; deny LAN; deny internet (best practice, confirm cloud deps first) |

**New-device default:** unknown MACs land in **Zone 3 (IoT Insecure)** — least-trust fallback, deliberately stricter than Ubiquiti's native default (documented deviation; see best-practices notes).

## § Live Device Inventory (2026-10-21 pull)

### Migration groups by blast radius
1. **Group 1** — wifi sensors/plugs (Zone 3): Amazon plugs ×9, KP115 ×3, esp32c3, Tstat ×3
2. **Group 2** — appliance ecosystems (Zone 2): LG washer/dryer, MyQ, Aqara, Envoy, adsb-monitor
3. **Group 3** — security-sensitive (Zone 4): Ring, wired cameras E1/Garage/Side/Living-Room, Reolink, Alexa
4. **Group 4** — stays in Trusted (Zone 1): iPhone, Steam Deck, wbw-desktop, wbw-media, wbw-ha + the two unknown port-3 wired hosts (identify first)

## 0. Stack facts (updated)

| Dependency | Status |
|---|---|
| **Pi-hole** | Docker on `wbw-ha` (10.0.0.16), port 53 on host. Cross-VLAN usable; Zone 2/3/4 get DNS-only firewall rule to 10.0.0.16:53 |
| **Mosquitto** | Docker on `wbw-ha`, bound 127.0.0.1 currently. Binding change to host LAN IP needed only if Zone-2 devices publish MQTT directly (check `wlan0`/`esp32c3`) |
| **UniFi controller** | Docker on `wbw-ha`, `/mnt/halfToshibaB/docker/data/unifi-config` (repo's `unifi.yml` updated 2026-10-22 to reflect this path) |
| **Controller auth** | `/api/login` (legacy) works; `/api/auth/login` (modern) returns 401 regardless of credentials — scripts/MCP must use legacy path. Account: `unifi-mcp`, 2FA-free local admin |
| **USG-3P firmware 4.4.57** | Final release (hardware EOL). Accepted risk — no newer firmware exists; if VLAN bugs surface, workaround or gateway replacement |
| **Backups** | ✅ Native `.unf` autobackup confirmed working (2026-10-22). Daily file-level general-backup zips to Google Drive cover the config tree |
| **Beyond the server.yml** | Repo's `backup.yml` backup paths on `wbw-ha` point to `/mnt/halfToshibaB/...` (the deployed paths), not the repo-file paths — a README/config sync candidate, not a blocker |

## 1. Phase 0 — Done / remaining

- ✅ Controller access via `unifi-mcp` local admin
- ✅ Firmware check — all gear at current/final release (USG EOL-final; Lite-16 has a newer build available, queue switch firmware update opportunistically)
- ✅ Native `.unf` autobackup confirmed + manual pre-change backup taken (2026-10-22, kept on wbw-ha)
- ✅ Traffic analysis for device placement (see § Groups)
- ✅ Lite-16-PoE re-adopted (was state 2 / adopted=False; now state 1, port table visible)
- ✅ **Phase 1 complete**: `IoT HA` (VLAN 2), `IoT Insecure` (VLAN 3), `IoT Secure` (VLAN 4) all created, corporate purpose, DHCP .100–.199, DNS=10.0.0.16, mDNS off — verified via API read-back 2026-10-22
- ⬜ Identify what is a *print device* for printer-zone choice (Canon wifi confirmed; Brother not seen — decide placement)
- ⬜ Phase 2: RADIUS enable + table import (below)
- ⬜ Phase 3: device moves + wired port changes (below)
- ⬜ Phase 4: firewall lockdown
- ⬜ PR #56 (mDNS reflector) merge + deploy after Lite-16 port 16 trunk

## 2. Phase 1 — Build the networks (zero-impact)

1. **Rename `Secure` → `IoT` (VLAN 2)**, convert from vlan-only to full network:
   - Subnet `10.0.2.1/24`, DHCP enabled (UniFi serves), DNS = `10.0.0.16` (Pi-hole)
   - mDNS: leave *off* initially; enable scoped only if a cast/AirPlay device lands here
2. **Create `IoT Insecure` (VLAN 3)**, subnet `10.0.3.1/24`, same DNS, same rules — this is also the RADIUS fallback zone.
3. **Create `IoT Secure` (VLAN 4)**, subnet `10.0.4.1/24`, same DNS — no internet egress initially (camera-guide best practice; verify Ring/Reolink/Alexa cloud deps before deciding to keep this deny).
4. **Firewall rules drafted but not applied** — all three zones stay inert until referenced by SSID/RADIUS.

## 3. Phase 2 — Wire the transport (RADIUS MAC-VLAN)

**No device-side wifi changes.** SSIDs (`Ninjatali`, `Ninjatali-5G`, `Ninjatali-IoT`) unchanged.

### Verified physical topology (2026-10-22, controller port/LLDP data)

```
USG-3P (gateway, LAN port 1)
  └─ US-8-60W (10.0.0.96)                  ← head switch (uplink to USG port 1)
       ├─ port 2 → Living-Room (Apple TV — Zone 3 target)
       ├─ port 3 → USW-Lite-16-PoE interconnect
       ├─ port 5 → Guest-bedroom AP
       ├─ port 7 → Flex Mini 24:5a:4c (desk switch)
       │            ├─ port 3 → wbw-desktop (Zone 1)
       │            └─ port 4 → ff-18919 FlightFeeder (Zone 3 target)
       └─ port 8 → Alex's Office AP
  └─ USW-Lite-16-PoE (10.0.0.97)           ← reached via US-8-60W port 3
       ├─ port 2  → Master-bedroom AP
       ├─ port 13 → wbw-media (Zone 1)
       └─ port 16 → wbw-ha (Zone 1; future mDNS-reflector host, needs VLAN 3 trunk)
```

All in-path hardware is Ubiquiti-managed — no unmanaged switch anywhere to strip 802.1Q tags.

1. Enable controller-integrated RADIUS; MAC format `AABBCCDDEEFF` (no separators — per Ubiquiti's Help Center doc 115004589707).
2. **Import MAC→VLAN table** (see § RADIUS table below) — one entry per known device; unknown/missing MACs fall to Zone 3.
3. Enable **RADIUS MAC Auth** on `Ninjatali` and `Ninjatali-5G` (one re-provision; devices reconnect automatically, no config change).
4. Wired devices move by port config — see the table below (executed in Phase 3).

### Wired port changes (executed in Phase 3, after RADIUS path is validated)

| Port | Device | Change | Notes |
|---|---|---|---|
| Flex Mini `24:5a:4c:...` port 4 | ff-18919 | **Native VLAN 3** | single-device port; clean Zone-3 isolation, no trunk needed |
| US-8-60W port 7 | desk Flex Mini uplink | **add Tagged VLAN 3** | carries VLAN 3 upstream to the desk switch |
| US-8-60W port 2 | Living-Room Apple TV | **Native VLAN 3** | single-device port; only after mDNS reflector is live |
| Lite-16 port 16 | wbw-ha | **add Tagged VLAN 3** (native stays 1) | prereq for PR #56 reflector macvlan |
| Lite-16 port 13 | wbw-media | none | stays Zone 1 |
| AP ports (Lite-16 p2, US-8-60W p5/p8) | APs | none | wifi handled entirely by RADIUS |

### Caveats
- Controller outage at association time: unknown MACs → fallback Zone 3 (safe, isolated); existing associations persist.
- mDNS does not cross VLANs: **needs the scoped reflector (PR #56)** once the Apple TV / Chromecast move — reflect filter covers `_airplay`, `_raop`, `_googlecast` only; cameras/IoT-HA zones are never reflected.

## 4. Phase 3 — Migrate devices (one group at a time, test as you go)

Aligned with best-practice: per-move verification, not end-of-migration debugging.

1. Group 1 → Zone 3, batch of ~5 then ping/test from Zone 1
2. Group 2 → Zone 2, one at a time (these sulk — power-cycle after move)
3. Group 3 → Zone 4, seeded last (highest emotional cost)
4. Wired devices via port profile flip (native VLAN change)

### Monitoring before Phase 2 (unresolved, prerequisite)
HA-side binary_sensor group of ~20 HA-visible devices as a "before" heartbeat; triggers a regression alert if any goes unavailable >2-3 min during or after its move.

## 5. Phase 4 — Firewall lockdown (only after everything works)

| Source → Dest | 1 Trusted | 2 IoT-HA | 3 IoT-Insec | 4 IoT-Sec | Internet |
|---|---|---|---|---|---|
| 1 Trusted | — | allow | allow (incl. adsb/feeder web-UI allows) | allow | allow |
| 2 IoT-HA | → HA-host only (8123/1883/dev ports), DNS | — | deny | deny | allow |
| 3 IoT-Insec | DNS only; *from* Trusted: respond to adsb web UI (allow established/return, since Trusted initiated) | deny | — | deny | allow |
| 4 IoT-Sec | → per-camera IP only | deny | deny | — | deny (confirm cloud deps first) |

Plus Pi-hole reachable from all zones on :53 (UDP+TCP) only.
Plus Zone-3 mDNS reflector statics (`10.0.0.65` ↔ `10.0.3.65`) can send/receive multicast 224.0.0.251:5353 in both zones.

## 6. Phase 5 — Cleanup & docs
- Delete nothing until 2 weeks zero-hit.
- Update README with VLAN map/firewall posture/port map per best practice.


## 7. RADIUS table draft (MAC → manufacturer → zone)

OUI (first 3 MAC octets) mapped via the IEEE registry. ❓ = needs human confirm.

| MAC | Name | Manufacturer | Kind | Zone | Notes |
|---|---|---|---|---|---|
|`ec:71:db:52:c2:ac`|E1|Reolink Innovation Limited|wired|4|Reolink cam|
|`48:a2:e6:0b:7f:8c`|Tstat-0B7F8C|Resideo|wifi|2|Resideo tstat|
|`de:5c:bc:bf:1c:2b`|Chromecast Garage TV|? (randomize OUI not in base)|wifi|3|Garage TV Chromecast (was misattributed as Apple TV wifi side)|
|`88:a2:9e:a5:3b:4f`|ff-18919|Raspberry Pi (Trading) Ltd|wired|3|FlightFeeder ADS-B (arrived 2026-10-21)|
|`48:a2:e6:34:51:02`|Tstat-345102|Resideo|wifi|2|Resideo tstat|
|`2c:3b:70:7e:2b:69`|steamdeck|AzureWave Technology Inc.|wifi|1|steamdeck|
|`54:af:97:09:cf:43`|KP115|TP-Link Systems Inc|wifi|3|KP115 plug|
|`ec:71:db:4e:2e:e1`|Side|Reolink Innovation Limited|wired|4|Reolink cam|
|`e8:65:38:53:2b:3b`|BRWE86538532B3B|CLOUD NETWORK TECHNOLOGY SINGAPORE PTE. LTD.|wifi|3|BroadLink white-label|
|`08:a6:bc:e4:dc:0b`|(unnamed)|Amazon Technologies Inc.|wifi|3|Amazon device (Echo?)|
|`54:af:97:09:9e:ae`|KP115|TP-Link Systems Inc|wifi|3|KP115 plug|
|`ba:45:32:61:07:b6`|iPhone|?|wifi|1|iPhone|
|`08:7c:39:d5:ff:71`|AmazonPlug02JR|Amazon Technologies Inc.|wifi|3|Amazon plug|
|`b0:4a:39:05:59:e9`|(unnamed)|Beijing Roborock Technology Co., Ltd.|wifi|3|Roborock|
|`84:78:48:b8:46:70`|(unnamed)|Ubiquiti Inc|wired|1|Ubiquiti gear|
|`c4:f7:c1:38:2a:3b`|Living-Room|Apple, Inc.|wired|1|Apple wired (identify)|
|`fc:49:2d:fc:d7:96`|amazon-e3fb1ddb7|Amazon Technologies Inc.|wifi|3|Amazon device|
|`50:03:cf:7b:13:98`|(unnamed)|CANON INC.|wifi|❓|Canon (printer?)|
|`ec:71:db:8e:30:63`|Garage|Reolink Innovation Limited|wired|4|Reolink cam|
|`58:d6:1f:1b:04:07`|(unnamed)|Ubiquiti Inc|wired|1|Ubiquiti gear|
|`7c:d5:66:15:83:30`|AmazonPlug02MC|Amazon Technologies Inc.|wifi|3|Amazon plug|
|`44:00:49:8b:1d:ad`|AmazonPlug0KH7|Amazon Technologies Inc.|wifi|3|Amazon plug|
|`ac:f1:08:d1:9f:73`|LG_Smart_Dryer2_open|LG Innotek|wifi|2|LG dryer|
|`ac:f1:08:80:dc:98`|LG_Smart_Laundry2_open|LG Innotek|wifi|2|LG washer|
|`b0:4a:39:1a:3a:36`|(unnamed)|Beijing Roborock Technology Co., Ltd.|wifi|3|Roborock|
|`bc:5f:f4:97:24:af`|wbw-ha|ASRock Incorporation|wired|1|wbw-ha server|
|`50:dc:e7:f0:e8:2f`|amazon-276610f0d|Amazon Technologies Inc.|wifi|3|Amazon device|
|`70:85:c2:d9:43:cc`|wbw-desktop|ASRock Incorporation|wired|1|wbw-desktop|
|`74:4d:bd:bf:15:50`|esp32c3-BF1550|Espressif Inc.|wifi|2|ESP32-C3|
|`4c:a1:61:07:a8:74`|(unnamed)|Rain Bird Corporation|wifi|2|Rain Bird irrigation|
|`18:c0:4d:03:1a:03`|wbw-media|GIGA-BYTE TECHNOLOGY CO.,LTD.|wired|1|wbw-media server|
|`08:7c:39:ae:00:db`|amazon-fc207eded|Amazon Technologies Inc.|wifi|3|Amazon device|
|`fc:a1:83:1d:9a:d4`|(unnamed)|Amazon Technologies Inc.|wifi|3|Amazon device (Echo?)|
|`cc:9e:a2:fc:d5:82`|AmazonPlug13XW|Amazon Technologies Inc.|wifi|3|Amazon plug|
|`44:00:49:30:ed:6c`|AmazonPlug494X|Amazon Technologies Inc.|wifi|3|Amazon plug|
|`54:ef:44:30:5e:a5`|Aqara-Hub-M2-5EA5|Lumi United Technology Co., Ltd|wifi|2|Aqara hub|
|`68:15:79:09:2d:0d`|(unnamed)|BrosTrend Technology LLC|wifi|❓|BrosTrend wifi adapter|
|`94:3a:91:59:6d:6a`|amazon-9c2f0b661|Amazon Technologies Inc.|wifi|3|Amazon device|
|`ca:6a:10:00:0c:06`|MyQ-A7F|?|wifi|2|MyQ garage|
|`b0:4a:39:05:61:b3`|(unnamed)|Beijing Roborock Technology Co., Ltd.|wifi|3|Roborock|
|`84:e3:42:6c:04:40`|wlan0|Tuya Smart Inc.|wifi|2|Tuya module|
|`48:a2:e6:31:46:fc`|Tstat-3146FC|Resideo|wifi|2|Resideo tstat|
|`9c:76:13:38:0d:c7`|Ring-380dc7|Ring LLC|wifi|4|Ring doorbell|
|`b8:27:eb:b8:eb:fa`|adsb-monitor|Raspberry Pi Foundation|wifi|3|Pi (adsb)|
|`2c:ab:33:cb:21:99`|envoy|Texas Instruments|wifi|3|Enphase Envoy|
|`54:af:97:0a:11:68`|KP115|TP-Link Systems Inc|wifi|3|KP115 plug|



## 8. Things likely to bite

1. **USG-3P at 4.4.57** — accepted as EOL/final. If a VLAN bug surfaces, no firmware fix exists.
2. **`/api/auth/login` vs `/api/login`** — this controller only accepts the legacy path.
3. **`wbw-ha` is the keystone** — stays put; only IoT devices move.
4. **Two unnamed wired port-3 hosts** — identify before migration.
5. **Camera cloud dependencies** — verify before enforcing deny-internet in Zone 4.
6. **RADIUS MAC format consistency** — Ubiquiti requires one format across all entries; mixing fails silently.
7. **`IoT Secure` internet-deny is strictest-practice but may break Ring/Reolink cloud features** — resolve before applying.
