#!/usr/bin/env python3
"""Add the 18 resolved Criterion movies to Radarr: unmonitored, no search.

Radarr 4.4 quirk: POSTing a minimal stub (tmdbId only) NREs in
MovieFolderAsRootFolderValidator. The full lookup resource must be POSTed back.
"""
import json, os, sys, time, urllib.request, urllib.error

BASE = "http://localhost:7878/api/v3"
KEY = os.environ["RADARR_API_KEY"]

MOVIES = [
    4538,   # The Darjeeling Limited 2007
    11159,  # Secrets & Lies 1996
    79120,  # Weekend 2011 (Andrew Haigh)
    22267,  # Ride with the Devil 1999 (Ang Lee)
    13685,  # Bottle Rocket 1996 (feature)
    16372,  # The Innocents 1961 (Jack Clayton)
    827,    # Diabolique / Les Diaboliques 1955
    5562,   # Le Beau Serge 1958
    2363,   # The Cousins / Les Cousins 1959
    11316,  # Macbeth 1971 (Polanski)
    17346,  # Grey Gardens 1975
    5336,   # Salò, or the 120 Days of Sodom 1975
    11368,  # Blood Simple 1984
    2469,   # Tie Me Up! Tie Me Down! 1989
    36843,  # Life Is Sweet 1990
    14022,  # Slacker 1991
    11660,  # Following 1998
    39800,  # Life During Wartime 2009
]

def req(method, path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    r = urllib.request.Request(f"{BASE}{path}", data=data, method=method,
                               headers={"X-Api-Key": KEY, "Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=90) as resp:
        body = resp.read().decode()
        return json.loads(body) if body else {}

added, failed = [], []
for tmdb in MOVIES:
    try:
        res = req("GET", f"/movie/lookup/tmdb?tmdbId={tmdb}")
        res["monitored"] = False
        res["qualityProfileId"] = 1
        res["rootFolderPath"] = "/data/movies"
        res["addOptions"] = {"searchForMovie": False}
        res.pop("id", None)
        m = req("POST", "/movie", res)
        added.append((tmdb, m["id"], m["title"]))
        print(f"added tmdb={tmdb} -> movieId={m['id']} {m['title']} ({m['year']})", flush=True)
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        try:
            msg = json.loads(body).get("message", "")[:150]
        except Exception:
            msg = body[:150]
        failed.append(tmdb)
        print(f"FAILED tmdb={tmdb}: HTTP {e.code} {msg}", flush=True)
    time.sleep(2)

print(f"\n{len(added)} added, {len(failed)} failed")
if failed:
    sys.exit(1)
