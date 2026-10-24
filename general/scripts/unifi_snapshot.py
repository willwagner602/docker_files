#!/usr/bin/env python3
"""UniFi controller snapshot: per-client VLAN/traffic record → JSONL.

Writes /out/<date>-snapshot.jsonl; one line per known client. Cron-friendly:
run via `python /snapshot.py` inside the uni-analytics container (read-only
against the controller).
"""
import json, os, re, ssl, sys, datetime as dt, http.cookiejar, urllib.request

OUT_DIR = os.environ.get('OUT_DIR', '/out')
HOST = os.environ['UNIFI_HOST']
USER = os.environ['UNIFI_USERNAME']
PASS = os.environ['UNIFI_PASSWORD']

BASE = f"https://{HOST}:{os.environ.get('UNIFI_PORT','443')}"
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
jar = http.cookiejar.CookieJar()
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar),
        urllib.request.HTTPSHandler(context=ctx))
UA = {'Content-Type': 'application/json', 'User-Agent': 'Mozilla/5.0'}

def call(path, data=None, method=None):
    body = json.dumps(data).encode() if data is not None else None
    m = method or ('POST' if body else 'GET')
    r = op.open(urllib.request.Request(BASE + path, data=body, headers=UA, method=m), timeout=30)
    return json.loads(r.read())

call('/api/login', {"username": USER, "password": PASS})
csrf = next((c.value for c in jar if c.name == 'csrf_token'), None)
if csrf:
    UA['X-Csrf-Token'] = csrf

sta = call('/api/s/default/stat/sta')['data']
nets = {n['_id']: n.get('name') for n in call('/api/s/default/rest/networkconf')['data']}

today = dt.date.today().isoformat()
out_path = os.path.join(OUT_DIR, f"{today}-snapshot.jsonl")
with open(out_path, 'a') as f:
    for c in sta:
        nname = nets.get(c.get('network_id') or '', 'unknown')
        row = {
            'ts': dt.datetime.now().isoformat(timespec='seconds'),
            'mac': c.get('mac'),
            'name': c.get('name') or c.get('hostname'),
            'ip': c.get('ip'),
            'vlan_network': nname,
            'is_wired': c.get('is_wired'),
            'essid': c.get('essid'),
            'sw_port': c.get('sw_port'),
            'last_seen_age_s': c.get('last_seen') and (int(dt.datetime.now().timestamp()) - c['last_seen']),
            'tx_bytes': c.get('tx_bytes'),
            'rx_bytes': c.get('rx_bytes'),
            'uptime': c.get('uptime'),
        }
        f.write(json.dumps(row) + '\n')
print(f"wrote {len(sta)} client rows -> {out_path}")
