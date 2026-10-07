#!/usr/bin/env python3
"""Sonarr: add 'World on a Wire' (tvdb 281573) unmonitored, import Part1/Part2 as S01E01/E02."""
import json, os, sys, time, urllib.request, urllib.error

BASE = "http://localhost:8989/api/v3"
KEY = os.environ["SONARR_API_KEY"]
DL = "/data/downloads/radarr/CRiTERiON.COLLECTiON.1080p.BluRay.x264-MiXED"
BR = {"quality": {"id": 7, "name": "Bluray-1080p"}, "revision": {"version": 1, "real": 0}}
TVDB = 281573

def req(method, path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    r = urllib.request.Request(f"{BASE}{path}", data=data, method=method,
                               headers={"X-Api-Key": KEY, "Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=90) as resp:
        b = resp.read().decode()
        return json.loads(b) if b else {}

# 1. add series
series = [s for s in req("GET", "/series/lookup?term=Welt%20am%20Draht") if s.get("tvdbId") == TVDB][0]
series.update(monitored=False, qualityProfileId=1, rootFolderPath="/data/tv",
              addOptions={"monitor": "none", "searchForMissingEpisodes": False})
series.pop("id", None)
s = req("POST", "/series", series)
sid = s["id"]
print(f"added series id={sid} {s['title']} ({s.get('year')})", flush=True)
time.sleep(3)

# 2. episode ids
eps = req("GET", f"/episode?seriesId={sid}")
for e in eps:
    print(f"  S{e.get('seasonNumber'):02d}E{e.get('episodeNumber'):02d} id={e['id']} {e.get('title','')}", flush=True)
e1 = [e for e in eps if e.get("episodeNumber") == 1][0]["id"]
e2 = [e for e in eps if e.get("episodeNumber") == 2][0]["id"]

# 3. manual import with explicit mapping
jobs = [
    (f"{DL}/World.On.A.Wire.1973.Part1.1080p.BluRay.x264-CiNEFiLE/World.On.A.Wire.1973.Part1.1080p.BluRay.x264-CiNEFiLE.mkv", [e1]),
    (f"{DL}/World.On.A.Wire.1973.Part2.1080p.BluRay.x264-CiNEFiLE/World.On.A.Wire.1973.Part2.1080p.BluRay.x264-CiNEFiLE.mkv", [e2]),
]
for path, epids in jobs:
    payload = {"name": "ManualImport",
               "files": [{"path": path, "seriesId": sid, "episodeIds": epids, "quality": BR}],
               "importMode": "copy"}
    try:
        cmd = req("POST", "/command", payload)
        for _ in range(60):
            c = req("GET", f"/command/{cmd['id']}")
            if c["status"] in ("completed", "failed"):
                break
            time.sleep(1)
        print(f"import {path.rsplit('/',1)[-1]}: cmd={c['status']}", flush=True)
        if c["status"] == "failed":
            print(json.dumps(c.get("exception", ""))[:300], flush=True)
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {e.read().decode()[:300]}", flush=True)
    time.sleep(2)

# 4. verify
efs = req("GET", f"/episodefile?seriesId={sid}")
print(f"\n{len(efs)} episode files:", flush=True)
for ef in efs:
    print(f"  S{ef.get('seasonNumber'):02d}E{ef.get('episodeNumber'):02d} {ef['path']}", flush=True)
sys.exit(0 if len(efs) == 2 else 1)
