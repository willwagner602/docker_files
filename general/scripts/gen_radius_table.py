#!/usr/bin/env python3
"""Generate the RADIUS MAC→VLAN user list for UniFi's built-in RADIUS.

Reads the live client state (from /tmp/unifi_state.json if present, else the
controller API) and/or the zone-map file, and emits two outputs:

1. --radius  : a machine-importable JSON of RADIUS users (name=password=MAC,
               AABBCCDDEEFF format, one VLAN id per device per zone map)
2. --table   : the human-readable markdown table for the migration doc

Usage:
    python3 gen_radius_table.py --state /tmp/unifi_state.json \
        --zones /tmp/zone_map.json --markdown radius_table.md --json radius_users.json
"""
import json, argparse, sys, os

# MAC → (zone, human note). Zones per the 4-zone design.
DEFAULTS = {
    # Zone 1 — Trusted (stays untagged / VLAN 1)
    'bc:5f:f4:97:24:af': 1,  # wbw-ha server
    '70:85:c2:d9:43:cc': 1,  # wbw-desktop
    '18:c0:4d:03:1a:03': 1,  # wbw-media (server)
    'ba:45:32:61:07:b6': 1,  # iPhone
    '2c:3b:70:7e:2b:69': 1,  # steamdeck
    '84:78:48:b8:46:70': 1,  # Ubiquiti wired gear
    '58:d6:1f:1b:04:07': 1,  # Ubiquiti wired gear (Lite-16 downstream MAC)
    'c4:f7:c1:38:2a:3b': 1,  # Living-Room Apple TV (wired) — pending: move to 3 when cast works
    # Zone 2 — IoT HA (VLAN 2)
    '54:ef:44:30:5e:a5': 2,  # Aqara hub
    '48:a2:e6:0b:7f:8c': 2,  # Resideo tstat
    '48:a2:e6:34:51:02': 2,  # Resideo tstat
    '48:a2:e6:31:46:fc': 2,  # Resideo tstat
    '4c:a1:61:07:a8:74': 2,  # Rain Bird irrigation
    'ac:f1:08:d1:9f:73': 2,  # LG dryer
    'ac:f1:08:80:dc:98': 2,  # LG washer
    'ca:6a:10:00:0c:06': 2,  # MyQ garage
    '74:4d:bd:bf:15:50': 2,  # ESP32-C3
    '84:e3:42:6c:04:40': 2,  # Tuya module (wlan0)
    # Zone 3 — IoT Insecure (VLAN 3). Default fallback zone too.
    '54:af:97:09:cf:43': 3, '54:af:97:09:9e:ae': 3, '54:af:97:0a:11:68': 3, # KP115 ×3
    '08:7c:39:d5:ff:71': 3, '7c:d5:66:15:83:30': 3, '44:00:49:8b:1d:ad': 3,  # AmazonPlug
    'cc:9e:a2:fc:d5:82': 3, '44:00:49:30:ed:6c': 3,
    '08:7c:39:ae:00:db': 3, '50:dc:e7:f0:e8:2f': 3, '94:3a:91:59:6d:6a': 3,  # Amazon/Echo
    'fc:49:2d:fc:d7:96': 3, 'fc:a1:83:1d:9a:d4': 3, '08:a6:bc:e4:dc:0b': 3,
    'b0:4a:39:05:59:e9': 3, 'b0:4a:39:1a:3a:36': 3, 'b0:4a:39:05:61:b3': 3,  # Roborock ×3
    '2c:ab:33:cb:21:99': 3,  # Enphase Envoy
    'b8:27:eb:b8:eb:fa': 3,  # adsb-monitor Pi
    '88:a2:9e:a5:3b:4f': 3,  # ff-18919 FlightFeeder
    'e8:65:38:53:2b:3b': 3,  # BRWE86538532B3B (BroadLink wl)
    'de:5c:bc:bf:1c:2b': 3,  # Chromecast Garage TV
    # Zone 4 — IoT Secure (VLAN 4)
    '9c:76:13:38:0d:c7': 4,  # Ring doorbell
    'ec:71:db:52:c2:ac': 4,  # Reolink E1
    'ec:71:db:4e:2e:e1': 4,  # Reolink Side
    'ec:71:db:8e:30:63': 4,  # Reolink Garage
    '68:15:79:09:2d:0d': 4,  # BrosTrend outdoor-cam bridge
    # ❓ pending — devices to decide before Phase 2 import (kept out of the
    #    import table until you settle each one; they fall to Zone 3 meanwhile)
    '50:03:cf:7b:13:98': None,  # Canon printer
}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--state', default='/tmp/unifi_state.json')
    ap.add_argument('--outdir', default='/tmp')
    a = ap.parse_args()

    st = json.load(open(a.state))
    rows = []
    for c in st['clients']:
        mac = (c.get('mac') or '').lower().replace(':', '')
        if not mac:
            continue
        name = c.get('name') or c.get('hostname') or 'unknown'
        zone = DEFAULTS.get(c.get('mac', '').lower())
        rows.append({
            'name': f'{name[:30].replace(" ", "_")}-{mac[-4:]}',  # RADIUS-friendly
            'username': mac,          # Ubiquiti requires MAC-as-username
            'password': mac,          # and MAC-as-password (same string, no separators)
            'vlan_id': zone,          # None = not yet decided (falls back)
            'kind': 'wired' if c.get('is_wired') else 'wifi',
            'ip_today': c.get('ip'),
            'essid': c.get('essid'),
        })

    decided = [r for r in rows if r['vlan_id']]
    json.dump({
        'radius_users': decided,
        'fallback_vlan': 3,
        'pending_review': [r for r in rows if not r['vlan_id']],
        'generate_api': 'POST one RADIUS user per link: /api/s/default/rest/radiususer',
    }, open(os.path.join(a.outdir, 'radius_users.json'), 'w'), indent=1)

    # markdown table
    md = ['# RADIUS MAC→VLAN import table\n',
          f'| username/password (MAC) | name | VLAN | kind |', '|---|---|---|---|']
    for r in decided:
        md.append(f"| `{r['username']}` | {r['name']} | {r['vlan_id']} | {r['kind']} |")
    md.append(f"\n**Fallback for unknown MACs: VLAN 3 (IoT Insecure).** "
              f"{len(rows)-len(decided)} device(s) pending zone assignment.")
    open(os.path.join(a.outdir, 'radius_table.md'), 'w').write('\n'.join(md) + '\n')
    print(f"wrote {len(decided)} radius users + pending queue; markdown in {a.outdir}/radius_table.md")

if __name__ == '__main__':
    main()
