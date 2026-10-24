#!/usr/bin/env python3
"""Serve the UniFi client snapshot as a live, sortable, filterable webpage.

GET /      → HTML table (client-side JS: column sort + text/zone filtering)
GET /api   → same data as JSON

Read-only against the controller (legacy /api/login). Fast responses: data is
scraped in a background thread every 20s; requests serve the cached render.
"""
import json, os, ssl, time, threading, datetime as dt, http.cookiejar, urllib.request
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

HOST = os.environ['UNIFI_HOST']
API_PORT = os.environ.get('UNIFI_PORT', '443')
USER = os.environ['UNIFI_USERNAME']
PASS = os.environ['UNIFI_PASSWORD']
PORT = int(os.environ.get('SERVE_PORT', '8092'))

BASE = f"https://{HOST}:{API_PORT}"
# UNIFI_VERIFY_SSL: "false" (default) trusts the controller's self-signed cert.
# Set to "true" after installing the controller cert into the system CA store.
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

def call(path, data=None):
    body = json.dumps(data).encode() if data is not None else None
    r = op.open(urllib.request.Request(BASE + path, data=body, headers=UA,
        method='POST' if body else 'GET'), timeout=30)
    return json.loads(r.read())

def _fetch():
    call('/api/login', {"username": USER, "password": PASS})
    csrf = next((c.value for c in jar if c.name == 'csrf_token'), None)
    if csrf:
        UA['X-Csrf-Token'] = csrf
    sta = call('/api/s/default/stat/sta')['data']
    nets = {n['_id']: n.get('name') for n in call('/api/s/default/rest/networkconf')['data']}
    wlans = {w['_id']: w.get('networkconf_id') for w in call('/api/s/default/rest/wlanconf')['data']}
    now = int(dt.datetime.now().timestamp())
    rows = []
    for c in sta:
        vlan = nets.get(c.get('network_id')) or nets.get(c.get('last_connection_network_id')) \
               or nets.get(wlans.get(c.get('wlanconf_id'))) or 'unknown'
        rows.append({
            'name': c.get('name') or c.get('hostname') or '(unnamed)',
            'ip': c.get('ip') or '?',
            'vlan': vlan,
            'kind': 'wired' if c.get('is_wired') else 'wifi',
            'essid': c.get('essid') or '',
            'sw_port': c.get('sw_port') or '',
            'mac': c.get('mac') or '',
            'tx': c.get('tx_bytes') if c.get('tx_bytes') is not None else (c.get('wired-tx_bytes') or 0),
            'rx': c.get('rx_bytes') if c.get('rx_bytes') is not None else (c.get('wired-rx_bytes') or 0),
            'last_seen_s': now - c['last_seen'] if c.get('last_seen') else None,
        })
    return rows

_CACHE = {'rows': None, 'err': None, 'at': 0}

def _bg_loop():
    while True:
        try:
            _CACHE['rows'] = _fetch()
            _CACHE['err'] = None
        except Exception as e:
            _CACHE['err'] = str(e)
        _CACHE['at'] = dt.datetime.now().timestamp()
        time.sleep(20)

PAGE = """<!doctype html><html><head><meta charset=utf-8>
<title>UniFi clients — live</title>
<style>
body{font:14px/1.45 system-ui;margin:2rem;color:#222;background:#fafafa}
h1{font-size:1.2rem;margin:0 0 .5rem}
.meta{color:#667;margin-bottom:.7rem}
#filter{width:340px;padding:6px 10px;font:inherit;border:1px solid #ccc;border-radius:6px}
#zoneSel{margin-left:10px;padding:6px 8px;font:inherit;border:1px solid #ccc;border-radius:6px}
table{border-collapse:collapse;width:100%;background:#fff;margin-top:1rem}
th,td{border:1px solid #e2e2e2;padding:6px 10px;text-align:left}
th{background:#eef;cursor:pointer;user-select:none;position:sticky;top:0}
th:after{content:'';opacity:.4;margin-left:4px}
th.asc:after{content:'▲';opacity:1} th.desc:after{content:'▼';opacity:1}
tr:hover td{background:#f2f6ff}
.iot{color:#a50;font-weight:600}
td .num{font-variant-numeric:tabular-nums}
</style></head><body>
<h1>UniFi clients — live snapshot</h1>
<div id=errbanner style="display:none;background:#fee;border:1px solid #c33;color:#900;padding:6px 10px;border-radius:6px;margin-bottom:.7rem"></div>
<div class=meta>auto-scrapes controller every 20s · data from <span id=gen>…</span> ·
<span id=n>…</span> clients · refreshed table every 30s
<button id=reload>reload data now</button></div>
<input id=filter placeholder="filter by any text…">
<select id=zoneSel><option value="">all zones</option></select>
<table id=t><thead><tr>
<th data-k=name>Device</th><th data-k=ip>IP</th><th data-k=mac>MAC</th><th data-k=vlan>VLAN / network</th><th data-k=kind>kind</th><th data-k=where>ESSID / port</th>
<th data-k=last_seen_s>last seen</th><th data-k=rx>rx</th><th data-k=tx>tx</th>
</tr></thead><tbody id=b>
</tbody></table>
<script>
let ROWS=[], SORTK='name', DIR=1, META=null;
const $=id=>document.getElementById(id);
function bytes2(n){let i=0;for(;n>=1024&&i<4;i++)n/=1024;return (i?n.toFixed(1):n)+['B','KB','MB','GB','TB'][i];}
function esc(s){return String(s).replace(/[&<>"']/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
function cell(r,k){
  switch(k){
    case 'where': return esc(r.essid || (r.sw_port?('port '+r.sw_port):''));
    case 'last_seen_s': return r.last_seen_s==null?'?':r.last_seen_s+'s ago';
    case 'rx': case 'tx': return '<span class=num>'+bytes2(r[k])+'</span>';
    default: return esc(r[k]);
  }
}
function render(){
  const d=META||{};
  const f=$('filter').value.toLowerCase(), z=$('zoneSel').value;
  let rows=ROWS.filter(r=>(!z||r.vlan===z)&&(!f||JSON.stringify(r).toLowerCase().includes(f)));
  rows.sort((a,b)=>{
    if(SORTK==='where'||SORTK==='ip'){
      if(SORTK==='ip'){
        const pa=(a.ip||'').split('.'), pb=(b.ip||'').split('.');
        for(let i=0;i<4;i++){const d=(parseInt(pa[i],10)||0)-(parseInt(pb[i],10)||0); if(d)return d*DIR;}
        return 0;}
      if(a.essid && b.essid) return String(a.essid).localeCompare(String(b.essid))*DIR;
      if(a.essid && !b.essid) return -1*DIR;
      if(!a.essid && b.essid) return 1*DIR;
      const p=(parseInt(a.sw_port,10)||0)-(parseInt(b.sw_port,10)||0);
      return p*DIR;}
    const x=a[SORTK],y=b[SORTK];
    if(x==null&&y==null)return 0; if(x==null)return 1; if(y==null)return -1;
    if(SORTK==='last_seen_s'){const d=(a.last_seen_s??-1)-(b.last_seen_s??-1); if(d)return d*DIR; return 0;}
    if(typeof x==='number'&&typeof y==='number')return (x-y)*DIR;
    return String(x).localeCompare(String(y))*DIR;});
  $('b').innerHTML=rows.map(r=>'<tr class="'+(String(r.vlan||'').toLowerCase().indexOf('iot')===0?'iot':'')+'">'+
    ['name','ip','mac','vlan','kind','where','last_seen_s','rx','tx'].map(k=>'<td>'+cell(r,k)+'</td>').join('')+'</tr>').join('');
  $('n').textContent=rows.length+' of '+ROWS.length;
  // "data from" reflects the last successful scrape, not browser render time,
  // so stale rows look stale; errbanner shows the last scrape error.
  const srcMs=d.err_at?d.err_at*1000:null;
  $('gen').textContent=srcMs?new Date(srcMs).toLocaleTimeString()+' (stale)':'never';
  const eb=$('errbanner');
  if(d.err){eb.style.display='block';eb.textContent='last scrape failed: '+d.err;}else{eb.style.display='none';}
}
function load(){
  fetch('/api').then(q=>q.json()).then(d=>{
    ROWS=d.clients||[];
    META=d;
    // Preserve the user's zone selection across the 30s auto-refresh; the
    // dropdown is rebuilt with esc()d options but value/selection is restored.
    const sel=$('zoneSel').value;
    const zs=[...new Set(ROWS.map(r=>r.vlan))];
    $('zoneSel').innerHTML='<option value="">all zones</option>'+zs.map(z=>'<option>'+esc(z)+'</option>').join('');
    $('zoneSel').value=sel;
    render();
  });
}
document.querySelectorAll('th[data-k]').forEach(th=>th.onclick=()=>{
  const k=th.dataset.k;
  if(SORTK===k)DIR*=-1;else{SORTK=k;DIR=1;}
  document.querySelectorAll('th').forEach(x=>x.classList.remove('asc','desc'));
  th.classList.add(DIR>0?'asc':'desc');
  render();
});
$('filter').oninput=render;
$('zoneSel').onchange=render;
$('reload').onclick=load;
setInterval(load,30000);
load();
</script></body></html>"""

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/api':
            try:
                rows = _CACHE['rows']
                if rows is None:
                    rows = _fetch()
                body = json.dumps({'generated': dt.datetime.now().isoformat(timespec='seconds'),
                                   'err': _CACHE['err'],
                                   'err_at': _CACHE['at'] or None,
                                   'clients': rows}, indent=1).encode()
                self.send_response(200)
                self.send_header('Content-Type','application/json')
            except Exception as e:
                body = json.dumps({'error': str(e)}).encode()
                self.send_response(502)
                self.send_header('Content-Type','application/json')
        else:
            body = PAGE.encode()
            self.send_response(200)
            self.send_header('Content-Type','text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass

if __name__ == '__main__':
    threading.Thread(target=_bg_loop, daemon=True).start()
    print(f"serving on :{PORT} (GET / HTML, /api JSON)", flush=True)
    ThreadingHTTPServer(('0.0.0.0', PORT), H).serve_forever()
