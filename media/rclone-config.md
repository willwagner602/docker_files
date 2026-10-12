# rclone setup (wbw-media)

How this machine syncs with Google Drive: an hourly **bidirectional sync** of
the whole Drive to a local mirror, plus a **daily one-way push** of the Immich
photo library. The nightly backup zips written by this machine's `media` stack
land in the mirror and ride the bisync up to Drive; the `general` stack on the
other host does the same from its side.

- Machine: `wbw-media` (Ubuntu 24.04)
- Binary: `/home/wbw/.local/bin/rclone` (rclone v1.75.0)
- Config: `/home/wbw/.config/rclone/rclone.conf` (single remote: `gdrive:` =
  the Google Drive root; OAuth token lives in this file — treat as secret)
- Units: `/etc/systemd/system/rclone-gdrive-bisync.{service,timer}`,
  `/etc/systemd/system/rclone-immich-push.{service,timer}` (root-owned; both
  `User=wbw`, installed 2026-10-12)

## Directory layout

```text
wbw-media
├── /home/wbw
│   ├── .config/rclone/rclone.conf      # remote "gdrive:" = Google Drive root (secret)
│   ├── .local/bin/rclone               # v1.75.0
│   ├── .local/state/pia-watchdog.log   # (unrelated cron, not rclone)
│   └── docker_files/                   # this repo (media stack definition)
│       ├── media/backup.yml            # nightly media backup; writes into the mirror
│       └── scripts/backup.sh           # shared backup script (lock via BACKUP_LOCK_DIR)
│
└── /bigdisk
    ├── google-drive/                   # LOCAL MIRROR of the entire Drive (bisynced hourly)
    │   ├── .bzvol/                     # Backblaze E: identity dir — excluded from sync
    │   ├── Immich Library/             # push target of rclone-immich-push
    │   ├── Server Backups/             # nightly backup zips (see "Backup integration")
    │   │   ├── general-backup-*.zip    #   written by the general stack (other host)
    │   │   └── media-backup-*.zip      #   written by this host's backup-media
    │   ├── Photos/ Finances/ Archive/ …# the rest of the personal Drive
    │   ├── DriveSyncFiles/             # artifacts of earlier sync tools (ignore)
    │   └── .tmp.drivedownload/
    ├── backup-locks/                   # media backup run lock — OUTSIDE the mirror, never synced
    └── immich/library/upload/ffb64a21-1742-43ee-aeb0-4e54c488de9c/
                                        # Immich originals = daily push source (also Backblaze D:)
/var/lib/rclone/bisync/                  # bisync state: listing databases + .lck
/run/lock/rclone-gdrive-bisync.lock      # flock: never two bisyncs at once
/etc/systemd/system/rclone-gdrive-bisync.{service,timer}
/etc/systemd/system/rclone-immich-push.{service,timer}
```

## Data flows

```text
Google Drive  ⇄  /bigdisk/google-drive          hourly bisync (both directions)
                                    ▲
                                    │ pushes new media-backup-*.zip
Backup on this host ────────────────┘            (04:00 America/Los_Angeles)

/bigdisk/immich/library/upload/…  ──one-way sync──►  gdrive:"Immich Library"   (daily 00:00 UTC)

general host (fd36e1c8d8c3) ──writes general-backup-*.zip──► Drive folder
                                    ◄──────── appears here via bisync
```

## rclone-gdrive-bisync (hourly, whole Drive)

`/etc/systemd/system/rclone-gdrive-bisync.service`:

```ini
[Unit]
Description=Bidirectional sync: Google Drive <-> /bigdisk/google-drive
Documentation=https://rclone.org/bisync/
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=wbw
Group=wbw
Nice=15
IOSchedulingClass=idle

ExecStart=/usr/bin/flock -n /run/lock/rclone-gdrive-bisync.lock /home/wbw/.local/bin/rclone bisync gdrive: /bigdisk/google-drive \
    --config=/home/wbw/.config/rclone/rclone.conf \
    --workdir=/var/lib/rclone/bisync \
    --fast-list \
    --transfers=8 \
    --checkers=16 \
    --track-renames \
    --create-empty-src-dirs \
    --max-delete=500 \
    --exclude "Immich Library/**" \
    --exclude "/.bzvol/**" \
    --retries=3 \
    --low-level-retries=10 \
    --log-level=INFO

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/rclone-gdrive-bisync.timer`:

```ini
[Unit]
Description=Run Google Drive <-> local bisync hourly

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
```

Notes:

- `Immich Library/**` is excluded because that folder is owned by the one-way
  push unit below (a bisync pass over it would fight the push).
- `/.bzvol/**` protects the Backblaze E: identity directory at the mirror root
  (it is the `.bzvol` bind-mounted into the `Backblaze64` container as
  `/drive_e/.bzvol`). Without the exclude, a sync would delete this empty
  local-only directory.
- `--max-delete=500` is the seatbelt: if a large chunk of the mirror ever
  disappears locally (or on Drive), the bisync aborts rather than replicating
  the deletion.
- `flock -n` means a manual start while an hourly run is in flight is a no-op,
  not a second concurrent sync.

## rclone-immich-push (daily, one-way)

`/etc/systemd/system/rclone-immich-push.service`:

```ini
[Unit]
Description=Sync Immich originals to Google Drive
Documentation=https://rclone.org/commands/rclone_sync/
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=wbw
Group=wbw
Nice=15
IOSchedulingClass=idle

ExecStart=/usr/bin/flock -n /run/lock/rclone-immich-push.lock /home/wbw/.local/bin/rclone sync /bigdisk/immich/library/upload/ffb64a21-1742-43ee-aeb0-4e54c488de9c "gdrive:Immich Library" \
    --config=/home/wbw/.config/rclone/rclone.conf \
    --fast-list \
    --transfers=8 \
    --checkers=16 \
    --track-renames \
    --max-delete=100 \
    --drive-stop-on-upload-limit \
    --retries=3 \
    --low-level-retries=10 \
    --log-level=INFO

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/rclone-immich-push.timer`:

```ini
[Unit]
Description=Run Immich originals upload daily

[Timer]
OnCalendar=*-*-* 00:00:00 UTC
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
```

One-way `sync` (mirror → Drive): files deleted from the Immich originals
directory are deleted from `gdrive:"Immich Library"` too, capped at
`--max-delete=100` per run. `--drive-stop-on-upload-limit` aborts if the Drive
account hits its daily upload quota. The source directory is the same upload
folder that Backblaze protects as drive **D:** (see `backblaze-wine/README.md`).

## Backup integration (media stack)

`media/backup.yml` mounts the mirror into the backup container and keeps the
run lock outside it:

```yaml
    environment:
      - BACKUP_AT=04:00            # America/Los_Angeles
      - DEST_DIR=/backups
      # The run lock lives on local disk (mounted at /locks), outside the
      # synced google-drive mirror, so it is never part of the Drive content
      # and never couples this stack to the general stack on the other host.
      - BACKUP_LOCK_DIR=/locks
    volumes:
      - "/bigdisk/google-drive/Server Backups:/backups"
      # --- run lock (local disk, outside the synced mirror) ---
      - /bigdisk/backup-locks:/locks
```

Consequences of this design:

- Zip files appear in `Server Backups/` locally and reach Drive on the next
  hourly bisync (upload latency ≤ 1 h after the 04:00 run).
- The run lock (`/bigdisk/backup-locks/.backup-lock`) is on plain local Btrfs,
  outside the bisynced tree, so it is never synced, never visible in Drive,
  and never couples this host to the general host. Each stack's lock is its
  own business; the two stacks may back up simultaneously.
- Because uploads are decoupled (hourly bisync), a failed upload never affects
  the backup run itself, and a missed bisync just delays the off-box copy.

## Relationship to Backblaze (drives D: and E:)

Backblaze does not use rclone. The `Backblaze64` container runs the Windows
client directly against Backblaze's servers and protects two read-only mounts
(full layout in `backblaze-wine/README.md`):

- **D:** `/bigdisk/immich/library/upload/ffb64a21-…` — the same Immich
  originals directory that `rclone-immich-push` copies to Drive.
- **E:** `/bigdisk/google-drive` — this mirror, including `Server Backups/`.

The bisync therefore feeds Backblaze's E: content — the backup archives in
`Server Backups/` are themselves backed up by Backblaze — but the two systems
are otherwise independent: rclone talks only to Google Drive, the Wine client
only to Backblaze. Drive-side deletions propagate through the bisync to E:
(capped by `--max-delete=500`); Backblaze's deleted-file history on its own
servers is the safety net if a Drive-side deletion should not have happened.

The `.bzvol` identity directories (bind-mounted into the container as
`/drive_d/.bzvol` and `/drive_e/.bzvol`) keep the two Backblaze drives'
identities stable; the bisync `--exclude "/.bzvol/**"` exists so sync churn can
never create or delete the mirror's copy of the E: anchor. Verified live
2026-10-12: client actively transmitting with both markers intact while the
bisync ran. Before touching anything under the marker paths, read
`backblaze-wine/README.md`.

## Common operations

```sh
# Schedules / last run / next run
systemctl list-timers --no-pager | grep rclone

# What the last bisync did (uploads, deletes, errors)
journalctl -u rclone-gdrive-bisync --since today --no-pager
journalctl -u rclone-immich-push  --since today --no-pager

# Kick a sync now (flock makes this safe any time)
sudo systemctl start rclone-gdrive-bisync.service

# See what is on Drive vs the mirror
rclone lsf --config ~/.config/rclone/rclone.conf "gdrive:Server Backups" | tail
ls -lt "/bigdisk/google-drive/Server Backups" | head

# Inspect a backup archive without extracting
unzip -l "/bigdisk/google-drive/Server Backups/media-backup-latest"*.zip | less
unzip -p  "/bigdisk/google-drive/Server Backups/media-backup-latest"*.zip backup-manifest.txt
```

Restore example (single file, preserving the path layout):

```sh
Z="/bigdisk/google-drive/Server Backups/media-backup-latest"*.zip
unzip -l $Z | grep 'prowlarr\.db$'                     # find the entry
unzip -j $Z 'bigdisk/prowlarr/prowlarr.db' -d /tmp/restore
```

### Changing bisync filters requires --resync

Bisync stores per-side listings and a filter hash in
`/var/lib/rclone/bisync`. Editing `--exclude` patterns (or the unit) invalidates
that state: the next hourly run fails with a filter/listing error until a
one-time resync is run with the exact same arguments plus `--resync`:

```sh
sudo systemctl stop rclone-gdrive-bisync.timer
sudo /usr/bin/flock -n /run/lock/rclone-gdrive-bisync.lock \
  /home/wbw/.local/bin/rclone bisync gdrive: /bigdisk/google-drive \
    --config=/home/wbw/.config/rclone/rclone.conf \
    --workdir=/var/lib/rclone/bisync \
    --fast-list --transfers=8 --checkers=16 --track-renames \
    --create-empty-src-dirs --max-delete=500 \
    --exclude "Immich Library/**" --exclude "/.bzvol/**" \
    --resync
sudo systemctl start rclone-gdrive-bisync.timer
```

Read `--resync` output before trusting it: it makes one side authoritative for
the first pass. Do not run a plain bisync or the resync by hand "as a test"
against the real mirror.

### Guard rails

- `--max-delete` (bisync 500, immich push 100): mass deletions abort instead of
  propagating. If a bisync aborts with a delete-limit error, investigate before
  re-running — it is telling you one side lost files.
- Backup archives are written as `<name>.zip.part` and renamed only when
  complete, so a bisync can never upload a half-written archive. A crashed run
  leaves the `.part` behind; the next run of the same role deletes it.
- The backup run lock (`/bigdisk/backup-locks/`) intentionally lives outside
  the mirror. Do not move it back into `Server Backups/`: it would sync to
  Drive and couple this host's runs to the general host's (this exact coupling
  made the two nightly backups starve each other on 2026-10-11/12).

## History / stale references

- 2026-10-12: replaced the old one-way pull unit `rclone-gdrive-sync.service`
  (and its `90-preserve-bzvol.conf` drop-in) with the bisync pair above. The
  `.bzvol` exclude was carried over into the bisync `ExecStart`.
- `backblaze-wine/README.md` and `media/backblaze-wine/rclone-preserve-bzvol.conf`
  still describe the removed pull unit — treat them as historical until updated.
- 2026-10-12: media backup moved its lock from
  `Server Backups/.backup-lock` to `/bigdisk/backup-locks/` and re-enabled a
  04:00 schedule; before that, both stacks' 04:00 runs contended for the same
  lock file inside the synced folder and silently starved each other.
