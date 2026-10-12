# Backblaze Personal Backup (Wine)

This standalone service is included by `media/compose.yaml` and runs as
`Backblaze64`. Its local Compose definition is `media/backblaze-wine/compose.yaml`.
It uses pinned image digest
`sha256:539ddfee2bfa0202801f799bac753a679f664986bc8ad9fd6b3ab94957b95d60`
and Backblaze client `10.0.1.1069` under Wine 11.0. Wine/Linux is outside
Backblaze's officially supported OS configurations.

## Deployed drive and filesystem layout

| Backblaze drive | Host source (Btrfs, read-only in container) | Writable marker (OS ext4) | Container target |
| --- | --- | --- | --- |
| D: | `/bigdisk/immich/library/upload/ffb64a21-1742-43ee-aeb0-4e54c488de9c` | `/home/wbw/backblaze-drive-markers/d` | `/drive_d` and `/drive_d/.bzvol` |
| E: | `/bigdisk/google-drive` | `/home/wbw/backblaze-drive-markers/e` | `/drive_e` and `/drive_e/.bzvol` |

The source binds are read-only; only the separate `.bzvol` marker binds are
writable. D preserves the prior volume identity. E has its own identity. Do not
copy D's marker identity to E or expose two copies of D's identity at once. The
layout requires no snapshots or OverlayFS and grants no extra container
capabilities, privileged mode, or AppArmor relaxation. Linux visibility alone
does not prove that Backblaze indexed or uploaded a file.

To inspect the rendered service and validate the full media Compose project:

```sh
docker compose -f media/compose.yaml config -q
docker compose -f media/compose.yaml ps backblaze-wine
```

The regular media project manages the container. Recreate it only when needed,
using `docker compose -f media/compose.yaml up -d --force-recreate backblaze-wine`.
Do not restart or recreate it during an active initial upload unless necessary;
first preserve the current client state and understand that restoring an old
config checkpoint can discard newer backup progress. Keep the existing image pin
and config bind when recreating.

## Recovery material and host configuration

- Persistent client config and backup bookkeeping: `/bigdisk/backblaze-personal/config`.
- D marker identity: `/home/wbw/backblaze-drive-markers/d`.
- Separate E marker identity: `/home/wbw/backblaze-drive-markers/e`.
- Restricted pre-migration recovery checkpoint: `/home/wbw/backblaze-evidence-g60amvei`.
- Earlier restricted checkpoint: `/home/wbw/backblaze-evidence-uxwgm222`.

Checkpoints contain sensitive client state. Retain them through implementation
review and restore verification; obtain operator approval before deleting them.
Prefer the current config and marker directories for ordinary recreation. Use a
checkpoint only for deliberate rollback/recovery, and do not restore an older
config over newer backup progress without understanding the consequences.

The Drive sync would normally prune or churn the empty root `.bzvol` anchor
directory. The bisync unit (`systemd/rclone-gdrive-bisync.service` in
`docker_files`) excludes `.bzvol` — the directory itself and its contents —
so rclone never lists, creates, or deletes it on either side. The former
`rclone-preserve-bzvol.conf` drop-in source belonged to the removed one-way
pull unit and is obsolete; it can be deleted with that unit's remaining
references. Do not run a sync as a test without separate approval.

## Backup state and verification

The live layout and identities were checked after deployment and a restart. The
operator selected E:; the client indexed 33,374 E: files. At the last recorded
progress snapshot, 1,543 indexed E: paths had path-specific transmission
records, with upload workers still active. This is partial progress, not proof of
complete coverage. D had 219,031 readable source files in the metadata inventory.
The full initial upload (about 1.6 TiB) and account restore verification remain
pending. Interrupted attempts and previous lock contention were observed; do not
interpret these as proof that the overall upload failed or completed. Check the
current client reports before making status claims.

A representative account restore has not been verified. To verify, download
representative files from both D: and E: using the account restore interface and
compare their SHA-256 hashes locally. Record the result separately from local
scan/transmission evidence. System exclusions, unreadable files, concurrent
source changes, and uncompleted transmission must be reconciled before claiming
whole-source coverage.

## Tests and evidence

Default tests are non-mutating; the Backblaze unit/static tests are included in
`make test` and can be run alone:

```sh
sh media/backblaze-wine/tests/tests.sh
```

Validate Compose with `docker compose -f media/compose.yaml config -q`.
Runtime Docker/client tests are explicitly opt-in and can affect a disposable
container or test mounts; read each runner's help and this README before running.
Never run fixture or destructive probes against the live D:/E: data roots. Evidence
bundles and recovery archives are sensitive; keep them outside the repository
with their restrictive permissions and do not commit them.

The isolated missing-bind test is:

```sh
python3 media/backblaze-wine/tests/runtime.py \
  --allow-disposable-docker-test --evidence-parent /home/wbw
```

The fixture setup/verification commands are implemented in
`media/backblaze-wine/tests/fixture.py`; they are not a substitute for live-source
coverage or account restore verification. The parser intentionally does not infer
success from generic counts or ambiguous log text. Unsupported or absent evidence
must remain unknown/blocked.

## Rollback and cleanup

Before changing mounts, stop the container and preserve a restricted checkpoint
of config, compose, mappings, selection, and marker identities. Restore the prior
Compose/mapping configuration only as an intentional rollback. Keep the E marker
separate; never clone D identity. Restore old config only if required, since it
can discard newer backup progress. Never delete source originals or uploaded
history. Do not remove legacy host mounts or recovery checkpoints without checking
consumers and obtaining operator approval where required.
