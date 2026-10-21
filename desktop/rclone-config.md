# Desktop rclone configuration: Google Drive bisync

This document describes the rclone setup on `wbw-desktop`. The desktop uses two-way bisync jobs between an external NTFS drive and Google Drive, plus a user-level staleness watcher. The separate `media` machine has its own Google Drive bisync; its unit and paths are not used on this desktop.

The repository version of the scripts and systemd user units lives under `scripts/` and `systemd/user/`. The installed copies in `~/.local/bin/` and `~/.config/systemd/user/` are machine-local. Keep them aligned with `make check-gdrive`.

## Machine and credentials

- Host: `wbw-desktop`.
- OS: Ubuntu 26.04.1 LTS (observed 2026-10-20).
- rclone executable: `~/.local/bin/rclone`, version 1.75.1. The scripts deliberately use this path rather than `/usr/bin/rclone`.
- Configuration: `~/.config/rclone/rclone.conf`; it contains the OAuth credentials and must be treated as secret. The configured remote name is `google drive:` (the only remote returned by `rclone listremotes` at inspection time). Never copy the config contents into documentation, logs, tickets, or the repository.
- The config file is owner-only (`0700` at inspection time). Preserve restrictive permissions and do not commit it.
- Shared filters: `~/.config/rclone/gdrive-sync-filters.txt`, installed from `systemd/user/gdrive-sync-filters.txt`.
- User service state and logs: `~/.local/state/gdrive-sync/`.
- Bisync listings/state: rclone's default per-user bisync state under `~/.cache/rclone/bisync/`; each path pair has its own listings.

## Storage and synced paths

The external volume is mounted at `/run/media/wbw/Slowby` and is currently `/dev/sdc2`, reported as `fuseblk` (NTFS). At inspection time it had about 7.3 TiB total, 3.6 TiB used, and 3.8 TiB available. These device and capacity values can change; use `findmnt` and `df` for current values.

| Job | Local path | Google Drive path | Purpose |
|---|---|---|---|
| Whole-tree | `/run/media/wbw/Slowby/Google Drive` | `google drive:` | Two-way bisync of the Drive root and local mirror. |
| Photos | `/run/media/wbw/Slowby/Google Drive/Photos` | `google drive:Photos` | Separate two-way bisync for the Photos subtree, with separate bisync state. |

The local Photos directory is a subtree of the whole-tree local directory, and the remote Photos path is also a subtree of the whole-tree remote. Both scripts use the same `flock` path, which is the only overlap guard. Always start syncs through these scripts or their systemd units; do not run a raw bisync for either pair concurrently.

## Data flow and schedules

```text
/run/media/wbw/Slowby/Google Drive  ⇄  google drive:
    whole-tree, systemd user timer every 10 minutes (current setting)

/run/media/wbw/Slowby/Google Drive/Photos  ⇄  google drive:Photos
    Photos-only pair, systemd user timer every minute

success markers  →  gdrive-sync-alert.service
    checks once per minute; alarms only 10:00–20:00 local time
```

The whole-tree timer is defined in `systemd/user/gdrive-sync.timer` with `OnCalendar=*-*-* *:0/10:00`, no random delay, and `Persistent=true`. It was changed from hourly to every two hours, then to every 15 minutes, and then every 10 minutes on 2026-10-21. The Photos timer remains `OnCalendar=*:*:00`, with one-second accuracy and `Persistent=false`. The watcher is a resident user service that restarts on failure.

At inspection on 2026-10-20, the whole-tree unit was running, and the last successful marker was from 11:12:52 PDT. The latest progress then showed 235,266 checks and 324,646 listed entries at about 37 minutes elapsed, with zero bytes transferred. The Photos success marker and log were still dated 2026-10-13 16:00:22 PDT; recent systemd Photos starts can finish after the non-blocking shared lock rejects the run. Do not interpret a successful systemd oneshot exit by itself as proof that Photos bisync ran; check the marker and log.

## Unit definitions

Repository unit files:

- `systemd/user/gdrive-sync.service` — whole-tree oneshot invoking `%h/.local/bin/gdrive-sync.sh`.
- `systemd/user/gdrive-sync.timer` — whole-tree schedule, currently every 10 minutes.
- `systemd/user/gdrive-sync-photos.service` — Photos oneshot invoking `%h/.local/bin/gdrive-sync-photos.sh`.
- `systemd/user/gdrive-sync-photos.timer` — Photos schedule, every minute.
- `systemd/user/gdrive-sync-alert.service` — always-running staleness watcher, `Restart=on-failure`.

The sync units run as systemd user services. The timers are enabled; the service units themselves are static oneshots. The scripts check that Slowby is mounted before invoking rclone.

## rclone options and filters

The whole-tree command is assembled in `scripts/gdrive-sync.sh`; the Photos command is assembled in `scripts/gdrive-sync-photos.sh`. Both use `--drive-import-formats docx,xlsx,pptx`, the shared filters file, INFO logging, `--max-lock 2m`, `--resilient`, and `--recover`.

The whole-tree job additionally uses `--fast-list` and `--checkers=16`. `--fast-list` uses recursive listing where supported, trading more memory for fewer listing transactions; `--checkers=16` runs more checks in parallel. These scan-speed options were added to the desktop whole-tree script on 2026-10-20, based on the corresponding media-host command. The Photos script does not currently use them. Subsequent whole-tree runs completed in roughly 3½–5¼ minutes, down from about 1h32m before the options were added; this is an observed before/after, not a controlled benchmark. A running rclone process does not inherit edits to its script, so the flags apply to future invocations.

The shared filter file excludes:

```text
- desktop.ini
- *.gsheet
- *.gdoc
- *.gslides
- *.gform
- *.gdraw
- *.lnk
```

These filters apply to both path pairs. Changing the filters changes the bisync filter hash and can require a deliberate `--resync`; do not change filters casually.

Unlike the media host's Drive bisync, the desktop whole-tree command does not exclude `Immich Library/**` and does not set the media host's `--transfers`, `--track-renames`, or `--max-delete` options. The media host runs a separate one-way Immich upload. Do not assume the two bisync commands cover identical trees or share state.

## Locking and success markers

Both scripts use `$XDG_RUNTIME_DIR/gdrive-sync.lock` (falling back to `/tmp/gdrive-sync.lock` when `XDG_RUNTIME_DIR` is unset):

- Whole-tree waits up to 240 seconds for the lock, then logs a skip and exits if it remains busy.
- Photos takes the lock non-blockingly. If busy, it skips that minute's tick without updating the success marker.

The scripts write success markers only after rclone exits successfully:

- `~/.local/state/gdrive-sync/last-sync.ok` — whole-tree.
- `~/.local/state/gdrive-sync/last-sync-photos.ok` — Photos.

Markers contain epoch seconds. They live under `$HOME`, so they persist across reboots. The watcher seeds missing markers with the current time on first run (trust-first behavior). It checks once a minute and alarms when a marker is at least six hours old, but only between 10:00 and 20:00 local time; while stale, it repeats at most hourly. A missing or malformed marker is treated as current time to avoid an immediate false alarm.

## Logs and status checks

- Whole-tree rclone log: `~/.local/state/gdrive-sync/sync.log`.
- Photos rclone log: `~/.local/state/gdrive-sync/photos-sync.log`.
- systemd journals: `journalctl --user -u gdrive-sync.service` and `journalctl --user -u gdrive-sync-photos.service`.
- Watcher journal: `journalctl --user -u gdrive-sync-alert.service`.

Useful non-mutating checks:

```sh
# Confirm mount, remote name, binary, and configured schedules
findmnt /run/media/wbw/Slowby
df -hT /run/media/wbw/Slowby
~/.local/bin/rclone version
~/.local/bin/rclone listremotes
systemctl --user list-timers 'gdrive-sync*'

# Check service state and recent systemd entries
systemctl --user status gdrive-sync.service gdrive-sync-photos.service gdrive-sync-alert.service
journalctl --user -u gdrive-sync.service -n 30 --no-pager
journalctl --user -u gdrive-sync-photos.service -n 30 --no-pager

# Check actual success times (systemd oneshot success alone is not enough)
date -d "@$(cat ~/.local/state/gdrive-sync/last-sync.ok)"
date -d "@$(cat ~/.local/state/gdrive-sync/last-sync-photos.ok)"
tail -n 40 ~/.local/state/gdrive-sync/sync.log
tail -n 40 ~/.local/state/gdrive-sync/photos-sync.log

# Check repo-vs-installed copies
cd ~/work/docker_files && make check-gdrive
```

To inspect a long-running whole-tree scan, look at recent `Checks`, `Listed`, `Transferred`, and `Elapsed time` lines in `sync.log`. Repeated checks with zero transferred bytes indicate scan/compare work, not that data is necessarily being copied.

## Manual operation

Run the scripts rather than `rclone bisync` directly so mount checks and the shared lock are honored:

```sh
~/.local/bin/gdrive-sync.sh
~/.local/bin/gdrive-sync-photos.sh
```

The scripts pass extra command-line arguments through to rclone. **`--resync` is destructive to bisync's normal conflict handling and chooses an authoritative side for the rebuild.** Only use it as a deliberate recovery, after reviewing rclone's path1/path2 meaning and the consequences for both copies. The first baseline for each pair also required its own `--resync`; do not rerun that baseline command as a test.

For ordinary interrupted runs, the scripts' `--max-lock 2m --recover --resilient` options handle common recovery cases. If recovery still fails, first verify that no bisync process is running. Delete a stale listing lock only as a last resort; if listings are corrupt, follow the recovery steps in `systemd/user/README.md` and inspect the exact paths before removing state.

## Install and update

The tracked files do not install themselves. The guarded Makefile target installs the scripts, user units, and filters. It requires explicit confirmation and checks that the Slowby mount exists unless the mount check is explicitly overridden:

```sh
cd ~/work/docker_files
make GDRIVE_INSTALL_CONFIRM=YES install-gdrive
systemctl --user daemon-reload
systemctl --user enable --now gdrive-sync.timer gdrive-sync-photos.timer gdrive-sync-alert.service
make check-gdrive
```

To update only the two-hour whole-tree timer after changing its repository file:

```sh
install -Dm 644 systemd/user/gdrive-sync.timer ~/.config/systemd/user/gdrive-sync.timer
systemctl --user daemon-reload
systemctl --user restart gdrive-sync.timer
systemctl --user list-timers gdrive-sync.timer
```

Restarting the timer does not cancel an already-running oneshot. Avoid restarting or stopping a bisync service merely to deploy script changes; the active process continues with the arguments it started with, and the new script takes effect on a later invocation.

## Related documentation

- `systemd/user/README.md` — install, recovery, and unit-specific operating notes.
- `media/rclone-config.md` — separate rclone configuration on the media host; its paths and exclusions differ from this desktop.