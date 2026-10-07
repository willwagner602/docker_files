#!/usr/bin/env python3
"""Import the 18 Criterion files into their newly added Radarr movies.

- ManualImport command per file with explicit movieId + quality (avoids the
  'NOT NULL constraint failed: MovieFiles.Quality' bug on unparsed quality).
- importMode copy (Radarr hardlinks via copyUsingHardlinks).
- DestinationAlreadyExists -> RescanMovie fallback (Radarr 4.4 quirk).
"""
import json, os, sys, time, urllib.request, urllib.error

BASE = "http://localhost:7878/api/v3"
KEY = os.environ["RADARR_API_KEY"]
DL = "/data/downloads/radarr/CRiTERiON.COLLECTiON.1080p.BluRay.x264-MiXED"

BR = {"quality": {"id": 7, "name": "Bluray-1080p"}, "revision": {"version": 1, "real": 0}}
RM = {"quality": {"id": 30, "name": "Remux-1080p"}, "revision": {"version": 1, "real": 0}}

JOBS = [
    (308, RM, "The Darjeeling Limited 2007 Criterion Collection REMUX 1080p Blu-ray AVC DTS-HD MA 5.1-LEGi0N/The.Darjeeling.Limited.2007.Criterion.Collection.REMUX.1080p.Blu-ray.AVC.DTS-HD.MA.5.1-LEGi0N.mkv"),
    (309, BR, "Secrets.and.Lies.1996.Criterion.1080p.BluRay.x264-nikt0/Secrets.and.Lies.1996.Criterion.1080p.BluRay.x264-nikt0.mkv"),
    (310, BR, "Weekend.2011.LIMITED.1080p.BluRay.X264-AMIABLE/Weekend.2011.LIMITED.1080p.BluRay.X264-AMIABLE.mkv"),
    (311, BR, "Ride.With.The.Devil.1999.1080p.BluRay.x264-NODLABS/ride.with.the.devil.1080p.bluray.x264-nodlabs.mkv"),
    (312, BR, "Bottle.Rocket.1996.1080p.BluRay.x264-CiNEFiLE/Bottle.Rocket.1996.1080p.BluRay.x264-CiNEFiLE.mkv"),
    (313, RM, "The Innocents 1961 Criterion Collection REMUX 1080p Blu-ray AVC LPCM 1.0-LEGi0N/The.Innocents.1961.Criterion.Collection.REMUX.1080p.Blu-ray.AVC.LPCM.1.0-LEGi0N.mkv"),
    (314, BR, "Les.Diaboliques.1955.1080p.BluRay.x264-PROFOUND/les.diaboliques.1955.1080p.bluray.x264-profound.mkv"),
    (315, BR, "Le.Beau.Serge.1958.1080p.BluRay.x264-CiNEFiLE/Le.Beau.Serge.1958.1080p.BluRay.x264-CiNEFiLE.mkv"),
    (316, BR, "Les.Cousins.1959.1080p.BluRay.x264-CiNEFiLE/Les.Cousins.1959.1080p.BluRay.x264-CiNEFiLE.mkv"),
    (317, BR, "Macbeth.1971.1080p.BluRay.x264-CiNEFiLE/the.tragedy.of.macbeth.1971.1080p.bluray.x264-cinefile.mkv"),
    (318, BR, "Grey.Gardens.1975.1080p.BluRay.x264-BRMP/grey.gardens.1975.1080p.bluray.x264-brmp.mkv"),
    (319, BR, "Salo.Or.The.120.Days.Of.Sodom.1975.RERIP.1080p.BluRay.x264-CiNEFiLE/Salo.Or.The.120.Days.Of.Sodom.1975.RERIP.1080p.BluRay.x264-CiNEFiLE.mkv"),
    (320, RM, "Blood Simple 1984 Remastered Criterion Collection REMUX 1080p Blu-ray AVC DTS-HD MA 5.1-LEGi0N/Blood.Simple.1984.Remastered.Criterion.Collection.REMUX.1080p.Blu-ray.AVC.DTS-HD.MA.5.1-LEGi0N.mkv"),
    (321, BR, "Tie.Me.Up.Tie.Me.Down.1989.1080p.BluRay.X264-Japhson/japhson-tie-1080p.mkv"),
    (322, BR, "Life.Is.Sweet.1990.PROPER.1080p.x264-SONiDO/lis1080-son.mkv"),
    (323, BR, "Slacker.1991.1080p.BluRay.X264-AMIABLE/Slacker.1991.1080p.BluRay.X264-AMIABLE.mkv"),
    (324, RM, "Following 1998 Criterion Collection BluRay 1080p REMUX AVC DTS-HD MA 5.1-LEGi0N/Following.1998.Criterion.Collection.BluRay.1080p.REMUX.AVC.DTS-HD.MA.5.1-LEGi0N.mkv"),
    (325, BR, "Life.During.Wartime.MULTi.1080p.BluRay.x264-ENjOi/enjoi-ldw.mkv"),
]

def req(method, path, payload=None, timeout=90):
    data = json.dumps(payload).encode() if payload is not None else None
    r = urllib.request.Request(f"{BASE}{path}", data=data, method=method,
                               headers={"X-Api-Key": KEY, "Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=timeout) as resp:
        body = resp.read().decode()
        return json.loads(body) if body else {}

def wait_command(cid, max_s=120):
    for _ in range(max_s // 2):
        c = req("GET", f"/command/{cid}")
        if c["status"] in ("completed", "failed"):
            return c
        time.sleep(1)
    return {"status": "timeout"}

ok, fixed, failed = [], [], []
for movie_id, quality, rel in JOBS:
    path = f"{DL}/{rel}"
    label = rel.split("/")[-1][:60]
    try:
        cmd = req("POST", "/command", {
            "name": "ManualImport",
            "files": [{"path": path, "movieId": movie_id, "quality": quality}],
            "importMode": "copy",
        })
        result = wait_command(cmd["id"])
        m = req("GET", f"/movie/{movie_id}")
        if m.get("hasFile"):
            ok.append((movie_id, m["title"]))
            print(f"OK  movieId={movie_id} {m['title']}", flush=True)
        else:
            # quirk: hardlink exists but DB record missing -> RescanMovie
            scan = req("POST", "/command", {"name": "RescanMovie", "movieId": movie_id})
            r2 = wait_command(scan["id"])
            m = req("GET", f"/movie/{movie_id}")
            if m.get("hasFile"):
                fixed.append((movie_id, m["title"]))
                print(f"OK* movieId={movie_id} {m['title']} (via RescanMovie)", flush=True)
            else:
                failed.append((movie_id, m["title"], result["status"]))
                print(f"FAIL movieId={movie_id} {m['title']} cmd={result['status']}", flush=True)
    except urllib.error.HTTPError as e:
        failed.append((movie_id, label, f"HTTP {e.code}"))
        print(f"FAIL movieId={movie_id} {label}: HTTP {e.code}", flush=True)
    time.sleep(2)

print(f"\n{len(ok)} imported, {len(fixed)} via rescan, {len(failed)} failed")
for f in failed:
    print("  FAILED:", f)
sys.exit(1 if failed else 0)
