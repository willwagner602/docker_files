# Immich deployment and one-time Google Photos migration

This directory contains repository-side operational assets for the dedicated Immich Compose project. The live Compose file, `.env`, generated credentials, logs, state, PostgreSQL data, media, and Takeout archives belong on the host under `/opt/immich`, `/srv/immich`, and `/srv/immich-migration`; they are not committed here.

## Deployment boundary

Immich is a separate Compose project named `immich`. Do not add its services to `plex/docker-compose.yml`, and use `docker compose -p immich ...` for every command. The Plex/Ombi PostgreSQL instance remains separate.

The deployment script downloads the official release `docker-compose.yml` and `example.env` from the concrete latest release, records URLs and hashes, preserves the upstream Compose file, and creates only a minimal bind-address override. It fails closed unless `/opt/immich/state/approved-bind-address` exists with mode `0600` and contains exactly one approved IPv4 address. Never use `0.0.0.0` or a public bind. The current host preflight found Docker CLI 29.7.2 but no `docker compose` plugin and no running daemon, so deployment is blocked until the operator installs/starts Docker using the official Fedora instructions.

After Docker is ready and the bind address is approved:

```sh
sudo install -d -m 700 /opt/immich/state
printf '%s\n' 10.0.0.15 | sudo tee /opt/immich/state/approved-bind-address >/dev/null
sudo chmod 600 /opt/immich/state/approved-bind-address
sudo ./immich/deploy.sh
```

The example above is only a placeholder for the operator's approved address; review firewall policy and use the exact intended address. The script does not install Docker, start the daemon, create an administrator, create an API key, or start an import.

## Host paths and backup

- Compose/runtime: `/opt/immich`
- Database: `/opt/immich/postgres` on a local Unix-compatible filesystem; never NFS/SMB/CIFS
- Media: `/srv/immich/library`
- Untouched Takeout ZIPs: `/srv/immich-migration/google-takeout`
- Logs/state: `/opt/immich/logs`, `/opt/immich/state`

Back up the media library and PostgreSQL using an Immich/PostgreSQL-consistent backup procedure. A naive live copy of `/opt/immich/postgres` is not sufficient as the sole database backup. Keep Plex/Ombi database backups separate.

## Health and persistence checks

```sh
cd /opt/immich
docker compose -p immich ps
docker compose -p immich config --quiet
curl --fail --max-time 15 http://127.0.0.1:2283/api/server/ping
docker stats --no-stream
df -h /opt/immich /srv/immich /srv/immich-migration
docker compose -p immich restart
```

Use the approved LAN address instead of `127.0.0.1` for a LAN client. PostgreSQL must not have a host port. Confirm the rendered service names, mounts, and networks do not collide with the Plex project.

## immich-go and migration wrapper

Install the architecture-matched stable `immich-go` binary with `immich/bin/install-immich-go.sh` (default verified version `v0.32.0`), verify `--version`, and record it in `/opt/immich/state/immich-go-version` plus a non-secret provenance file. The wrapper is `immich/bin/import-google-photos.sh`; install it to `/opt/immich/bin/import-google-photos.sh` with mode `0700`.

The verified `immich-go` v0.32.0 configuration documentation supports an `immich-go.toml` file with `[upload] api-key`. The wrapper creates that file in a private temporary directory and runs from that directory, so the API key is not placed in importer argv, logs, reports, or shell tracing. It requires `IMMICH_API_KEY` in the calling environment, checks Immich connectivity, requires at least one top-level `.zip`, preserves every source archive, and uses mode `0700`/`0600` permissions for temporary material. If the installed `immich-go` version does not support this configuration transport, the wrapper must fail closed; do not replace it with `--api-key`. The exact v0.32.0 release must be verified before installation and recorded in the host provenance manifest.

Copy the wrapper and run a dry run first:

```sh
sudo install -m 0700 immich/bin/import-google-photos.sh /opt/immich/bin/import-google-photos.sh
IMMICH_API_KEY='provided interactively, never committed' \
  /opt/immich/bin/import-google-photos.sh dry-run
```

Dry-run reports archive count/bytes and redacted importer findings; it never transitions to import. Import is explicit and resumable by rerunning the same command after reviewing results:

```sh
IMMICH_API_KEY='provided interactively, never committed' \
  /opt/immich/bin/import-google-photos.sh import
```

Defaults are conservative: four concurrent tasks, 60-minute client timeout, paused Immich jobs, continue-on-error, generated session tag, no `--overwrite`, and no `--include-unmatched`. The wrapper exposes `MANAGE_RAW_JPEG`, `MANAGE_HEIC_JPEG`, and `MANAGE_BURST`; defaults are `StackCoverRaw`, `StackCoverJPG`, and `Stack`. Test representative RAW/JPEG, HEIC/JPEG, Live Photo, burst, video, edited, geotagged, and album media before a full import. Never delete Takeout archives. The SIDECAR METADATA queue workaround is troubleshooting-only and must be applied manually only when needed.

Monitor `docker stats`, `docker compose -p immich ps`, disk space, database health, restarts, importer progress, and repeated API failures. Reports are written under `/opt/immich/state` without credentials.

## Manual handoff

1. Install/start Docker Engine and the Compose plugin; verify `docker info` and `docker compose version`.
2. Approve the exact local/LAN bind address and firewall/CIDR policy in `/opt/immich/state/approved-bind-address`.
3. Run the deployment and health/restart checks.
4. Create the first/admin Immich account at `http://SERVER_IP:2283`.
5. Create an Immich API key and provide it only through the calling environment.
6. Download all Google Photos-only Takeout ZIP parts into the migration directory.
7. Review dry-run findings and explicitly start import.
8. Spot-check representative assets and metadata; install/configure the iOS app.
9. Establish independent backups for media and PostgreSQL.

Recurring Google Photos synchronization and public exposure are out of scope.

## Tests

Repository/static unit tests use mocks and do not claim a real deployment:

```sh
./immich/tests/run.sh unit
```

Host tests require a real Docker daemon and an already deployed `/opt/immich` stack:

```sh
./immich/tests/run.sh host
```
