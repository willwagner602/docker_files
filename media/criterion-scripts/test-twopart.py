#!/usr/bin/env python3
"""Two-part film test: Children of Paradise (tmdb 2457), Radarr 4.4.4.

Import part 1, verify, then import part 2 and report whether Radarr keeps
both files (multi-file/edition) or replaces the first.
"""
import json, os, time, urllib.request, urllib.error

BASE = "http://localhost:7878/api/v3"
KEY = os.environ["RADARR_API_KEY"]
DL = "/data/downloads/radarr/CRiTERiON.COLLECTiON.1080p.BluRay.x264-MiXED"
BR = {"quality": {"id": 7, "name": "Bluray-1080p"}, "revision": {"version": 1, "real": 0}}

def req(method, path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    r = urllib.request.Request(f"{BASE}{path}", data=data, method=method,
                               headers={"X-Api-Key": KEY, "Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=90) as resp:
        b = resp.read().decode()
        return json.loads(b) if b else {}

def wait_command(cid, max_s=90):
    for _ in range(max_s):
        c = req("GET", f"/command/{cid}")
        if c["status"] in ("completed", "failed"):
            return c
        time.sleep(1)
    return {"status": "timeout"}

def state(mid, label):
    m = req("GET", f"/movie/{mid}")
    cnt = (m.get("statistics") or {}).get("movieFileCount")
    mf = m.get("movieFile") or {}
    print(f"[{label}] hasFile={m.get('hasFile')} movieFileCount={cnt} file={mf.get('path','-').split('/')[-1]}", flush=True)
    return m

# 1. add
res = req("GET", "/movie/lookup/tmdb?tmdbId=2457")
res.update(monitored=False, qualityProfileId=1, rootFolderPath="/data/movies",
           addOptions={"searchForMovie": False})
res.pop("id", None)
m = req("POST", "/movie", res)
mid = m["id"]
print(f"added Children of Paradise -> movieId={mid}", flush=True)
time.sleep(3)

# 2. import part 1
p1 = f"{DL}/Children.Of.Paradise.1.1945.1080p.BluRay.x264-HD4U/children.of.paradise.part.1.1945.1080p.bluray.x264-hd4u.mkv"
c = wait_command(req("POST", "/command", {"name": "ManualImport",
    "files": [{"path": p1, "movieId": mid, "quality": BR}], "importMode": "copy"})["id"])
req("POST", "/command", {"name": "RescanMovie", "movieId": mid})
time.sleep(4)
state(mid, "after part1")

# 3. import part 2, observe
p2 = f"{DL}/Children.Of.Paradise.2.1945.1080p.BluRay.x264-HD4U/children.of.paradise.part.2.1945.1080p.bluray.x264-hd4u.mkv"
c = wait_command(req("POST", "/command", {"name": "ManualImport",
    "files": [{"path": p2, "movieId": mid, "quality": BR}], "importMode": "copy"})["id"])
req("POST", "/command", {"name": "RescanMovie", "movieId": mid})
time.sleep(4)
m = state(mid, "after part2")
cnt = (m.get("statistics") or {}).get("movieFileCount")
print("VERDICT:", "BOTH FILES KEPT (multi-file works)" if (cnt or 0) >= 2 else "SECOND FILE REPLACED/FAILED (one file per movie)")
