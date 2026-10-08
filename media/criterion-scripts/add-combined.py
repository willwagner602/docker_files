#!/usr/bin/env python3
"""Radarr: reset CoP test state, add CoP + Brakhage, import combined files."""
import json, os, time, urllib.request, urllib.error

BASE = "http://localhost:7878/api/v3"
KEY = os.environ["RADARR_API_KEY"]
DL = "/data/downloads/radarr-manual"
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

def add(tmdb):
    res = req("GET", f"/movie/lookup/tmdb?tmdbId={tmdb}")
    res.update(monitored=False, qualityProfileId=1, rootFolderPath="/data/movies",
               addOptions={"searchForMovie": False})
    res.pop("id", None)
    m = req("POST", "/movie", res)
    print(f"added tmdb={tmdb} -> movieId={m['id']} {m['title']}", flush=True)
    return m["id"]

def import_file(mid, rel):
    path = f"{DL}/{rel}"
    wait_command(req("POST", "/command", {"name": "ManualImport",
        "files": [{"path": path, "movieId": mid, "quality": BR}], "importMode": "copy"})["id"])
    wait_command(req("POST", "/command", {"name": "RescanMovie", "movieId": mid})["id"])
    time.sleep(3)
    m = req("GET", f"/movie/{mid}")
    mf = m.get("movieFile") or {}
    ok = m.get("hasFile") and "radarr-manual" not in mf.get("path", "")
    print(f"import movieId={mid}: hasFile={m.get('hasFile')} path={mf.get('path','-')}", flush=True)
    return ok

# 1. remove test movie 326 (Children of Paradise), keep files
req("DELETE", "/movie/326?deleteFiles=false")
print("removed test movieId=326", flush=True)
time.sleep(2)

# 2. CoP: re-add and import combined
cop = add(2457)
time.sleep(3)
ok_cop = import_file(cop, "Children of Paradise 1945 1080p BluRay x264.mkv")
time.sleep(2)

# 3. Brakhage: add and import combined
brk = add(1417115)
time.sleep(3)
ok_brk = import_file(brk, "Brakhage on Brakhage 1996 1080p BluRay x264.mkv")

print("RESULT:", "OK" if (ok_cop and ok_brk) else "CHECK NEEDED")
