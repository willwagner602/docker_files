#!/usr/bin/env python3
"""UniFi controller snapshot: per-client VLAN/traffic record → JSONL.

Writes /out/<date>-snapshot.jsonl; one line per known client. Cron-friendly:
run via `python /snapshot.py` inside the uni-analytics container (read-only
against the controller).
"""
import json, os, ssl, datetime as dt, http.cookiejar, urllib.request

OUT_DIR = os.environ.get('OUT_DIR', '/out')
HOST = os.environ['UNIFI_HOST']
USER = os.environ['UNIFI_USERNAME']
PASS = os.environ['UNIFI_PASSWORD']

BASE = f"https://{HOST}:{os.environ.get('UNIFI_PORT','443')}"
# Same verify toggle as unifi_serve.py: set UNIFI_VERIFY_SSL=true once the
# controller cert is trusted in the system CA store.
verify = os.environ.get('UNIFI_VERIFY_SSL', 'false').lower() != 'false'
ctx = ssl.create_default_context()
if verify:
    ctx.check_hostname = True
    ctx.verify_mode = ssl.CERT_REQUIRED
else:
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

def main():
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

# Loop: take one snapshot per day at SNAPSHOT_HOUR local time, then sleep.
# (The container runs under restart: unless-stopped; without this loop it
# restarts ~every minute and floods the controller with logins. Retry once
# per hour on failure so a downtime blip doesn't spin.)
import time

def _next_run_hour():
    now = dt.datetime.now()
    hour = int(os.environ.get('SNAPSHOT_HOUR', '14'))
    nxt = now.replace(hour=hour, minute=0, second=0, microsecond=0)
    return nxt if nxt > now else nxt + dt.timedelta(days=1)

while True:
    nxt = _next_run_hour()
    time.sleep(max(1, (nxt - dt.datetime.now()).total_seconds()))
    try:
        main()
    except Exception as e:
        print(f"snapshot failed: {e}; retrying in 1h", flush=True)
        time.sleep(3600)
