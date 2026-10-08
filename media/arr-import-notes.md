# Servarr Import Notes

Operational reference for adding and importing media into Radarr/Sonarr on
this stack — API quirks, failure modes, and the patterns that work.

**Version applicability:** verified against **Radarr 4.4.4** and
**Sonarr 3.0.10** (both EOL). Re-verify this document after upgrading;
most of the Radarr bugs below are fixed in current releases.

## Environment map

| Item | Value |
|---|---|
| Radarr | container `radarr`, port 7878, API key in `media/.env` (`RADARR_API_KEY`) |
| Sonarr | container `sonarr`, port 8989, API key in `media/.env` (`SONARR_API_KEY`) |
| Library (movies) | container `/data/movies` = host `/bigdisk/plex/movies` |
| Library (TV) | container `/data/tv` = host `/bigdisk/plex/tv` |
| Downloads | container `/data/downloads/...` = host `/bigdisk/plex/downloads/...` |
| qBittorrent config | host `/media/qbittorrent/config` (**not** `/bigdisk` — watch for stale paths in older docs) |
| Import mode | `copy` + `copyUsingHardlinks: true` → library file is a hardlink of the seed file |
| Add pattern | `monitored: false`, `searchForMovie: false`, quality profile `Any` (id 1) |

## TMDb lookups without getting throttled

- Radarr/Sonarr proxy lookups to TMDb. Parallel bulk scans trip throttling:
  `SkyHookException … Invalid response received from TMDb` (inner
  `TaskCanceledException`) or empty result sets.
- **Empty results are not proof a title is missing** — titles that returned
  nothing in a parallel scan matched exactly when retried slowly.
- Reliable pattern: sequential text lookups spaced ~2 s apart, or resolve the
  TMDb/TVDb ID out-of-band (web search) and fetch by ID:
  `GET /movie/lookup/tmdb?tmdbId=X` (Radarr),
  `GET /series/lookup?term=…` (Sonarr).
- Catalog quirk: miniseries live in TMDb as **TV series** (e.g. Fassbinder's
  *World on a Wire* = tv/86449). Radarr movie lookups will always miss them;
  they belong in Sonarr.

## Radarr quirks (4.4.4)

1. `POST /api/v3/movie` with a minimal stub (tmdbId only) → 500 NRE in
   `MovieFolderAsRootFolderValidator`. **POST the full lookup resource** with
   `monitored`/`qualityProfileId`/`rootFolderPath`/`addOptions` applied.
2. A file scans as `Unknown Movie` until a matching movie exists — **add
   first, then import** with an explicit `movieId`.
3. Unparsed quality → `NOT NULL constraint failed: MovieFiles.Quality` on
   import. Pass an explicit quality: Bluray-1080p = 7, Remux-1080p = 30.
4. `ManualImport` with `files[]` places the file but the MovieFiles DB row
   only appears after a follow-up `RescanMovie` command. Deterministic —
   always follow imports with a rescan.
5. Hardlink already at destination but DB row missing →
   `DestinationAlreadyExistsException`. Fix with `RescanMovie`, not re-import.
6. One movie = one file. Importing a second file **replaces** the first and
   deletes its library hardlink (the seed copy survives — hardlink).
7. Radarr ignores unrecognized extra files (e.g. `Movie (Year)-extra1.mkv`)
   in a movie folder on rescan — safe spot for Plex extras.
8. ManualImport from a folder outside the configured download-client roots
   does a real **copy**, not a hardlink.
9. Wrong quality on an imported file can be corrected with
   `PUT /api/v3/moviefile/{id}`.

## Sonarr quirks (3.0.10)

1. Adding a series requires a valid `languageProfileId` (1) → otherwise HTTP 400.
2. `RenameFiles` command **requires** `files: [episodeFileIds]` — a null list
   NREs the command — and it no-ops when renaming is disabled in naming
   config.
3. Reliable rename alternative: `mv` files into `Season 1/` with
   `Series - SxxExx - Title.mkv` names (mv preserves hardlinks), then run the
   `RescanSeries` command. Plex needs season folders + SxxExx names to match.
4. Rescan re-parses quality from filenames and can record HDTV for BluRay
   sources — correct via `PUT /episodefile/{id}`.

## Multi-file media patterns

- **One film in two parts**: Radarr cannot hold both. Lossless option:
  `ffmpeg -f concat -safe 0 -i list.txt -map 0 -c copy out.mkv` — works only
  if ffprobe shows identical codec params across parts. (~Full film size in
  extra disk; the result is a standalone copy, not a hardlink.)
- **Miniseries**: add as a series in Sonarr; map files to episodes with
  `ManualImport` + explicit `episodeIds`.
- **Bonus features**: hardlink into the movie's folder as
  `<Movie (Year)>-extra1.mkv` — appears under Extras in Plex.
- For two files offered as duplicates (encode vs REMUX): prefer REMUX.

## Hardlink verification

After any import, confirm seeding safety:

```
stat -c '%d:%i' "<library file>" "<source file>"   # must match
stat -c '%h' "<source file>"                        # expect ≥2
```

## Reference implementations

`media/criterion-scripts/*.py` are working, sequential end-to-end flows
against the pinned versions above: movie add (full-resource POST),
ManualImport + RescanMovie, the two-file replacement test, a combined-file
import, and a Sonarr series add with explicit episode mapping.
