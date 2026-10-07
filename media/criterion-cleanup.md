# Criterion Collection Cleanup

Import of `CRiTERiON.COLLECTiON.1080p.BluRay.x264-MiXED` into Radarr/Sonarr.

**Status: COMPLETE** (finished 2026-09-25). Library: Radarr 327 movies / 312 with files; Sonarr +1 series. All original release files untouched on disk (seeding unaffected); every tracked library file verified as a hardlink (same device+inode as source) except the two concatenated files, which are new standalone copies.

## Environment

| Item | Value |
|---|---|
| Torrent folder (host) | `/bigdisk/plex/downloads/radarr/CRiTERiON.COLLECTiON.1080p.BluRay.x264-MiXED` |
| Same folder in Radarr/qBittorrent | `/data/downloads/radarr/CRiTERiON.COLLECTiON.1080p.BluRay.x264-MiXED` |
| Radarr | 4.4.4.7068, container `radarr`, port 7878, API key in `media/.env` |
| Sonarr | 3.0.10, container `sonarr`, port 8989, root `/data/tv` |
| Library root | `/data/movies` (host: `/bigdisk/plex/movies`) |
| Quality profile used | `Any` (ID 1), all movies added **unmonitored**, `searchForMovie: false` |
| Import mode | `copy` + `copyUsingHardlinks: true` |

## What was done in this final pass (2026-09-25)

1. **Section F — 12 previously throttled films** (`Les Diaboliques`, `Le Beau Serge`, `Les Cousins`, `Macbeth 1971`, `Grey Gardens`, `Salò`, `Blood Simple`, `Tie Me Up! Tie Me Down!`, `Life Is Sweet`, `Slacker`, `Following`, `Life During Wartime`): all resolved by **sequential, spaced Radarr text lookups** (1 request / 2 s). Every one matched uniquely on the first slow pass — the earlier failures were purely the parallel bulk scan tripping TMDb throttling. IMDb IDs verified.
2. **Section E resolved by TMDb ID**: Weekend 2011 → **79120**, Ride with the Devil → **22267**, Bottle Rocket → **13685** (all IMDb-confirmed). The Innocents 1961 → **16372** (tt0055018; the "second same-year match" was a Martinac short).
3. **18 films added + imported** (movieIds 308–325): full lookup resource POST (see quirk 6), ManualImport per file with explicit `movieId` + quality, then RescanMovie (see quirk 7). All 18 library files verified hardlinks (nlink=2). Quality records corrected for 3 files Radarr mis-guessed (japhson-tie / lis1080-son / enjoi-ldw) via `PUT /moviefile/{id}`.
4. **Section B**: The Innocents REMUX (LEGi0N) imported (16372); CiNEFiLE encode stays seed-only.
5. **Children of Paradise (1945)** — one film in two files. Verified empirically that Radarr 4.4.4 tracks ONE file per movie (importing part 2 replaced part 1 and deleted its library hardlink). Per operator choice, the parts were **concatenated losslessly** (ffmpeg `-f concat -c copy`, identical codec params confirmed by ffprobe) into a single 12.9 GB file (190 min), imported as Radarr movie **327** (tmdb 2457). The combined file is a real copy (not hardlink) since it lives outside Radarr's download roots — staging copy deleted.
6. **Brakhage on Brakhage I–IV** — same treatment: concatenated (I 1996 + II + III + IV 1997, identical codec params, 36 min) into one file, imported as Radarr movie **328** (tmdb 1417115, operator choice). Staging copy deleted.
7. **World on a Wire (1973)** — **not a TMDb movie**: it is TV series tv/86449 "Welt am Draht" (that's why every Radarr lookup failed). Added to **Sonarr** as series id 47 (tvdb 281573, unmonitored), both parts imported with explicit episode mapping (Part1→S01E01, Part2→S01E02), renamed to `Season 1/World on a Wire - S01E0x - Part x.mkv` (mv preserves inodes; hardlinks verified). Sonarr re-parse labeled the files HDTV-1080p; corrected to Bluray-1080p via `PUT /episodefile/{id}`.
8. **Jimi Hendrix Live at Monterey (1967)** — hardlinked as `Monterey Pop (1968)-extra1.mkv` inside Monterey Pop's library folder (surfaces under Extras in Plex). Verified safe: Radarr `RescanMovie` on 42632 left the movieFile unchanged and ignored the extra.
9. **False positive confirmed**: `refined-uninvited-blu1080p.mkv` scan entry was noise (no year in folder name); The Uninvited itself was imported in the previous pass.

## Scripts

`media/criterion-scripts/` — add-movies, import-files, test-twopart, add-combined, sonarr-woaw (`.py`, run with `set -a; source media/.env; set +a`). Concat lists: `/bigdisk/plex/downloads/radarr-manual/*-concat.txt`. ffmpeg came from a `linuxserver/ffmpeg` docker image (`-v /bigdisk/plex:/data`), as the host has no ffmpeg and no passwordless sudo.

## Radarr/Sonarr quirks learned (4.4.4 / Sonarr 3.0.10)

1. `GET /manualimport` without a `folder` param → 500. Always pass the folder.
2. A file scans as `Unknown Movie` when no library movie matches — movies must be **added first**, then imported with an explicit `movieId`.
3. `UNKNOWN` parsed quality → `NOT NULL constraint failed: MovieFiles.Quality` on import. Pass an explicit quality in the ManualImport payload.
4. Hardlink already at destination but DB record missing → `DestinationAlreadyExistsException`. Fix with `RescanMovie`, not re-import.
5. `importMode: "copy"` + `copyUsingHardlinks: true` = hardlink; verified via identical inode.
6. **POST /api/v3/movie with a minimal stub (tmdbId only) → 500 NRE in `MovieFolderAsRootFolderValidator`.** You must POST the full `/movie/lookup/tmdb` resource with the settings applied.
7. **ManualImport with `files[]` places the file but the MovieFiles DB row only appears after a follow-up `RescanMovie`** — happened for all 18 imports; deterministic, not a race.
8. Radarr is one-movie-one-file: importing a second file **replaces** the first (and deletes its library hardlink; seed copy safe). No multi-part movie support.
9. ManualImport from a folder outside the configured download-client roots does a real **copy**, not a hardlink.
10. Radarr ignores extra `-extra1.mkv` files in movie folders on rescan (safe for Plex extras).
11. Sonarr 3.0.10: series add requires a valid `languageProfileId` (1) or 400s. `RenameFiles` command **requires explicit `files: [episodeFileIds]`** or it NREs; and it no-ops when `renameEpisodes` is disabled in naming config. Manual `mv` + `RescanSeries` re-attaches renamed files cleanly.

## TMDb rate limiting (why lookups failed before)

Radarr proxies `/movie/lookup` to TMDb; bulk scans with 8–16 parallel workers tripped throttling (`SkyHookException`/`TaskCanceledException`, empty result sets). TMDb's documented limit was removed in 2019; practical ceiling ≈ 40–50 req/s. **Sequential spaced lookups (1 per 2 s) resolved 12/12 previously "missing" films with zero failures** — empty lookup results are never proof a film is absent; retry slowly or by TMDb ID.
