# Desktop rclone bisync: Google Drive (user units)

Two-way sync between the `Google Drive` folder on the external drive
`Slowby` (mounted at `/run/media/wbw/Slowby`, NTFS) and the rclone remote
`google drive:`, plus a desktop staleness alarm. Runs on the **desktop
machine as systemd user units** — these are machine-local, not compose
services, and live outside the container stack like the server-side
`systemd/rclone-*.service` units.

This in-repo file is the version reviewers and CI can see. The desktop-local
`~/work/computer-fixes/gdrive-sync.md` is a separate machine-local mirror; keep
both current.

## Jobs

| Job | Paths | Schedule | Log |
|---|---|---|---|
| `gdrive-sync` (whole tree) | `/run/media/wbw/Slowby/Google Drive` ↔ `google drive:` | every 10 min | `~/.local/state/gdrive-sync/sync.log` |
| `gdrive-sync-photos` (Photos only) | `.../Google Drive/Photos` ↔ `google drive:Photos` | every minute | `~/.local/state/gdrive-sync/photos-sync.log` |
| `gdrive-sync-alert` (watcher) | staleness check (both jobs) | always on | `journalctl --user -u gdrive-sync-alert` |

## Components

- `scripts/gdrive-sync.sh` → installed as `~/.local/bin/gdrive-sync.sh`.
  Whole-tree bisync. Skips if Slowby isn't mounted; waits up to 4 min for
  the shared lock. Writes `last-sync.ok` epoch marker on success.
- `scripts/gdrive-sync-photos.sh` → installed as
  `~/.local/bin/gdrive-sync-photos.sh`. Photos-only bisync, own bisync
  state. Non-blocking lock; writes `last-sync-photos.ok` on success.
- `scripts/gdrive-sync-alert.sh` → installed as
  `~/.local/bin/gdrive-sync-alert.sh`. Staleness watcher: alarms when a job
  has not succeeded for ≥ 6 h **and** local time is 10:00–20:00; repeats at
  most hourly while still stale. `GDRIVE_SYNC_ALERT_DRY=1` prints instead
  of notifying (for tests — a bare run *will* pop a real desktop
  notification). Names used in alarms: "Google Drive" (whole tree, covers
  photos) / "Google Drive Photos" (photos-only staleness).
- `systemd/user/gdrive-sync{,-photos}.{service,timer}` — the two sync jobs.
- `systemd/user/gdrive-sync-alert.service` — watcher (auto-restarts).
- `systemd/user/gdrive-sync-filters.txt` → installed as
  `~/.config/rclone/gdrive-sync-filters.txt`. Excludes `desktop.ini`,
  Google-Editor shortcut files (`.gsheet`/`.gdoc`/...) and `.lnk`.

## Important details

- **rclone binary**: `~/.local/bin/rclone` (v1.75.1, NOT `/usr/bin/rclone` —
  Ubuntu ships 1.60.1, whose bisync could not handle Google-Docs listings
  created by `--drive-import-formats`; this was confirmed by upstream issue
  #5696, but current behavior has not been re-verified after rclone 1.75.1).
- **Locking**: both sync jobs share `flock` on
  `$XDG_RUNTIME_DIR/gdrive-sync.lock`. Whole-tree waits up to 240s;
  photos is non-blocking (skips a tick if busy).
- **Separate bisync state per pair**: the photos job uses its own path
  pair, so its listings live in distinct files under `~/.cache/rclone/bisync/`.
  Both pairs currently use the same filters file. Changing it changes the filter
  hash for both pairs and can require `--resync`; do not run the same pair with
  different filters files. The shared flock is the only guard against overlap
  between the Photos subtree and whole-tree pair; always invoke these syncs
  through the scripts.
- Staleness and success-marker behavior below is code-derived (scripts + unit
  files in this directory).
- The `google drive{VTj1f}` name in logs is rclone's config-hash suffix for
  command-line `--drive-import-formats`. Harmless.
- **Argument pass-through**: `"$@"` forwards extra arguments to rclone. This
  is how `--resync` is passed; it can mutate both sides of the pair.
- **Success marker**: each job writes `~/.local/state/gdrive-sync/last-sync*.ok`
  (epoch seconds) on success. The state directory is under `$HOME`, so it
  persists across reboots.
- The arr client endpoint and Compose port mapping are configured separately;
  keep them in sync by hand.

## Install

`make install-gdrive` writes to live user configuration and therefore refuses
to run unless you explicitly confirm it:

```sh
make GDRIVE_INSTALL_CONFIRM=YES install-gdrive
```

It also requires `/run/media/wbw/Slowby` to exist as a host-appropriateness
check for this desktop. `GDRIVE_INSTALL=1` overrides only that mount check, not
the required confirmation. Install the required `~/.local/bin/rclone` v1.75.1
separately before enabling these units. `make check-gdrive` compares the
installed scripts, units, and filters with the repository; it is standalone and
is not part of `make check` or the pre-push gate.

```sh
cd ~/work/docker_files
install -m 755 scripts/gdrive-sync.sh scripts/gdrive-sync-photos.sh \
    scripts/gdrive-sync-alert.sh ~/.local/bin/
install -Dm 644 systemd/user/gdrive-sync.service \
    systemd/user/gdrive-sync.timer ~/.config/systemd/user/
install -Dm 644 systemd/user/gdrive-sync-photos.service \
    systemd/user/gdrive-sync-photos.timer ~/.config/systemd/user/
install -Dm 644 systemd/user/gdrive-sync-alert.service ~/.config/systemd/user/
install -Dm 644 systemd/user/gdrive-sync-filters.txt \
    ~/.config/rclone/gdrive-sync-filters.txt
systemctl --user daemon-reload
systemctl --user enable --now gdrive-sync.timer gdrive-sync-photos.timer \
    gdrive-sync-alert.service
```

First-ever run needs a baseline for each pair:

```sh
~/.local/bin/gdrive-sync.sh --resync
~/.local/bin/gdrive-sync-photos.sh --resync
```

## Recovery

If a bisync aborts (`cannot find prior listings` / `Bisync aborted. Must
run --resync`):

```sh
# one-time rebuild (Path1/local wins conflicts)
~/.local/bin/gdrive-sync.sh --resync          # whole tree
~/.local/bin/gdrive-sync-photos.sh --resync   # photos pair
```

If state is truly corrupt, wipe and resync (listings only — no user data):

```sh
rm -rf ~/.cache/rclone/bisync
~/.local/bin/gdrive-sync.sh --resync
~/.local/bin/gdrive-sync-photos.sh --resync
```

The scripts use `--max-lock 2m` to expire stale locks and `--recover` to
resume after interruptions without `--resync` in the common case. If recovery
still fails, first confirm no bisync process is running; only then, as a
last resort, delete the stale `*.lck` in `~/.cache/rclone/bisync/`.

## Status checks

```sh
systemctl --user list-timers 'gdrive-sync*'
journalctl --user -u gdrive-sync-photos.service -n 20
tail -20 ~/.local/state/gdrive-sync/sync.log
cat ~/.local/state/gdrive-sync/last-sync.ok ~/.local/state/gdrive-sync/last-sync-photos.ok
```

## History

- 2025-09-21–23: original 5-min bisync worked (before `--drive-import-formats`).
- 2025-09-24 10:31: import-formats added; Ubuntu rclone 1.60.1 bisync wrote
  Google-Docs listing lines it couldn't parse back → critical error → every
  run failed until repair.
- 2025-09-25: upgraded rclone to 1.75.1 in `~/.local/bin`, wiped state,
  resynced (2,580 files / 52 GiB), split into photos@1min + whole@hourly,
  added the alarm watcher.
- 2026-10-12 14:21: whole-tree run aborted (93 `chtimes` errors on `Immich
  Library` hash dirs — directories deleted mid-run, likely Immich churn).
  Watcher alarmed on each retry. Later that day the watcher was replaced
  with a staleness alarm (fires only if a job has not succeeded in 6 h,
  only 10:00–20:00, at most hourly repeats). At that point, the whole-tree
  pair still needed a manual `--resync`; the recovery flags added later are
  intended to handle interruptions without it in the common case. Photos healthy.
- 2026-10-12: scripts and units copied into this repo (`scripts/` +
  `systemd/user/`) with `systemd/user/README.md` as the setup doc.
- Cadence tuning since the 2025-09-25 "whole@hourly" entry above: hourly →
  every two hours (2026-10-20) → every 15 minutes → every 10 minutes
  (2026-10-21). The authoritative schedule is
  `gdrive-sync.timer`'s `OnCalendar`; also see `desktop/rclone-config.md`.
