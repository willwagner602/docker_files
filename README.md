# Docker Compose Services

Docker Compose definitions for the services running on the home & media servers. Each independent service or dependency group has its own Compose file so services can be upgraded, restarted, and deployed without bringing up unrelated containers.

## Repository layout

### `media/`

| Compose file | Services | Why they are grouped |
| --- | --- | --- |
| `arr.yml` | Sonarr, Radarr, Whisparr, Stash, Unpackerr | Unpackerr connects to Sonarr and Radarr using their Compose service names. Stash manages the separate Whisparr library. |
| `plex.yml` | Plex | Independent media server. |
| `ombi.yml` | Ombi | Independent request-management service. |
| `prowlarr.yml` | Prowlarr | Independent indexer manager. |
| `flaresolverr.yml` | FlareSolverr | Independent proxy/solver service. |
| `sabnzbd.yml` | SABnzbd | Independent download service. |
| `qbittorrent.yml` | qBittorrent | Independent download service. |
| `postgres.yml` | PostgreSQL | Separate database service. |
| `autoheal.yml` | Autoheal | Restarts unhealthy containers via a dedicated socket-proxy; its restart permission also allows stop and kill. |
| `health-notify-media.yml` | Health notifier | Watches all containers through the Docker socket; the media role adds disk, queue, Arr, and HTTP checks. |
| `frigate.yml` | Frigate | Independent NVR service. |
| `photo-uploader.yml` | Photo uploader | Uses a persistent SQLite volume plus a read-only photo-library bind mount. |

`media/compose.yaml` is the canonical media-server deployment. It sets the stable project name `media` and includes the component files, so the complete deployment can be managed without `-f` or `-p`. The ARR services remain in one component file because they communicate using Compose service names.

Autoheal does not mount the raw docker socket: it talks to a dedicated
socket-proxy (`autoheal-socket-proxy`). Autoheal itself only lists containers
and calls the restart endpoint. The proxy enables `CONTAINERS=1` and
`ALLOW_RESTARTS=1`, with other endpoint groups disabled. **Important:**
LinuxServer's `ALLOW_RESTARTS` toggle groups stop, restart, and kill endpoints;
it cannot allow restart without also allowing stop and kill. Those extra
operations are therefore available to a compromised Autoheal container, even
though Autoheal itself does not call them. The health-notify socket-proxy is
read-only by contrast (`POST=0`, `ALLOW_RESTARTS=0`).

### `general/`

| Compose file | Services | Why they are grouped |
| --- | --- | --- |
| `homeassistant.yml` | Home Assistant | Independent host-networked service. |
| `zwavejsui.yml` | Z-Wave JS UI | Independent service with its own network and persistent state. |
| `pihole.yml` | Pi-hole | Independent DNS service. |
| `nginx-proxy.yml` | Nginx Proxy Manager | Independent service on the shared `npm` Docker network. |
| `unifi.yml` | UniFi Network Application, MongoDB | UniFi uses `unifi-db` as its MongoDB hostname, so these services remain together. |
| `wg-easy.yml` | wg-easy | Independent service on the shared `npm` Docker network. |
| `tailscale.yml` | Tailscale | Independent host-networked service. |
| `owntracks.yml` | OwnTracks Recorder | Independent service with persistent state. |
| `mosquitto.yml` | Mosquitto | Independent service with persistent data and configuration. |
| `job-digest.yml` | Job Digest | Independent service using the `ghcr.io/willwagner602/job-search-tooling` image; state persists in the `/home/wbw/job-digest-state` bind mount. |
| `couchdb.yml` | CouchDB | Self-hosted Obsidian LiveSync backend; behind Nginx Proxy Manager over a dedicated `couchdb-net` Docker network shared only with the proxy, with data bind-mounted under `/home/wbw/couchdb`. |
| `mindwtr.yml` | Mindwtr Cloud | Sync server for the Mindwtr desktop and mobile apps; published only to Nginx Proxy Manager over a dedicated `mindwtr-net` Docker network, with data bind-mounted under `/home/wbw/mindwtr`. |
| `health-notify-general.yml` | Health notifier | Watches all containers through the Docker socket; the general role skips media-only checks and monitors the `willwagner.me` certificate. |

`general/compose.yaml` is the canonical general-server deployment. It sets the stable project name `general` and includes every service-level compose file. Shared networks retain their fixed names so services from separate files can communicate within the combined deployment.

### `desktop/`

| Compose file | Services | Why they are grouped |
| --- | --- | --- |
| `mcp.yaml` | — (aggregation only) | Groups every MCP server running on this machine so the layer above can include them as a unit. Each server lives in its own file. |
| `komodo-mcp.yml` | Komodo MCP | Read-only Komodo access for Polytoken agents, over loopback HTTP. Needs only outbound reach to Komodo Core and no Docker socket. |

`desktop/compose.yaml` is the canonical workstation deployment. It sets the stable project name `desktop` and includes `mcp.yaml`, which in turn includes each MCP server file. That is one layer deeper than the other two stacks: MCP servers are agent tooling rather than infrastructure, they are expected to grow, and keeping them behind an aggregation file means adding one is a one-line change there instead of an edit to the top-level file.

`general/` and `media/` are deployed to their own hosts. Nothing in `desktop/` is deployed to either, and nothing here is on the general or media stack.

### Other paths

| Path | Purpose |
| --- | --- |
| `general/.env.example`, `media/.env.example`, `desktop/.env.example` | Templates for the required per-stack variables. Copy to `.env` in the same directory and replace the values; `.env` is gitignored. |
| `scripts/health-notify.sh` | Health-notification script used by both stacks' notifier containers; mounted read-only into the container. |
| `scripts/tests/health-notify/` | Test suite for `health-notify.sh`, with stub binaries under `bin/`. Run with `make test`. |
| `Makefile` | Local entry points: `make test`, `make validate`, `make check`. |
| `.github/workflows/ci.yml` | CI: runs the shell test suite and validates every compose stack. |

## Running a service

The canonical files use top-level `include`, which requires Docker Compose 2.20.3 or newer.

Manage the complete media-server deployment from `media/`:

```sh
cd media
# Requires all media deployment variables, including PHOTO_UPLOADER_PHOTO_PATH and PHOTO_UPLOADER_* credentials.
docker compose up -d
docker compose ps
docker compose logs -f
```

Operate on an individual service through the same canonical model:

```sh
docker compose up -d plex
docker compose restart plex
docker compose logs -f plex
docker compose stop plex
```

Because `compose.yaml` contains the complete application model, whole-deployment lifecycle commands are predictable:

```sh
docker compose up -d --remove-orphans
docker compose down
```

Manage the complete general-server deployment the same way:

```sh
cd general
docker compose up -d
docker compose ps
docker compose logs -f
```

Individual general services can also be managed through the canonical model:

```sh
docker compose up -d unifi
docker compose logs -f unifi
```

## Configuration and host prerequisites

These files use host-specific bind mounts, device mappings, and environment variables. Before starting a service:

1. Confirm that the referenced host paths and devices exist. For CouchDB, create the bind-mount directories before the first start and give them to UID 5984, the `couchdb` user inside the container: `mkdir -p /home/wbw/couchdb/{data,etc} && chown -R 5984:5984 /home/wbw/couchdb`. Docker creates missing bind-mount sources as root-owned, which leaves CouchDB unable to write.
2. Provide required variables through an environment file or the shell. Examples include `POSTGRES_PASSWORD`, `SONARR_API_KEY`, `RADARR_API_KEY`, `SAB_API_KEY`, `COUCHDB_USER` and `COUCHDB_PASSWORD` for CouchDB, `PIHOLE_WEBPASSWORD`, `MONGO_INITDB_ROOT_PASSWORD`, `MONGO_PASS`, and `ZWAVE_SESSION_SECRET` for the general services, and the VPN variables used by SABnzbd and qBittorrent. Photo uploader additionally requires `PHOTO_UPLOADER_PHOTO_PATH`, operator credentials, a session secret, a Bluesky handle, and a Bluesky App Password; it stores its SQLite database in the named `photo-uploader-data` volume.
3. Review credentials and secrets before deployment. Some existing service definitions contain deployment-specific values and should be treated as sensitive.
4. Ensure the required Docker networks and host permissions are available.

The Compose files do not create host directories or hardware devices automatically.

## Monitoring (Komodo)

Both stacks run Komodo (https://komo.do) — a single dashboard endpoint for
Docker and service status across both hosts, with notifications (Telegram et
al., configured in the UI), per-container logs, and restart controls.

- `general/komodo.yml` runs Core (+ MongoDB) and the local Periphery agent.
  The UI is at `http://<general-host>:9120`; the initial admin is created from
  `KOMODO_INIT_ADMIN_*` in `general/.env` on first launch. Registration is
  disabled.
- `media/komodo.yml` runs the Periphery agent in outbound mode: it connects to
  Core on general (`ws://10.0.0.16:9120`) and opens no inbound port on media.
  One-time setup: log in to Core, create an onboarding key with privileged mode
  (Settings / Onboarding), put it in `media/.env` as `PERIPHERY_ONBOARDING_KEY`,
  then `docker compose up -d komodo-periphery`.

The Periphery agents mount the raw docker socket by design: they are management
agents that need write access (restart/stop, log reads), which the read-only
socket-proxy deliberately does not provide. Komodo's Mongo state and agent keys
are covered by the backup services; Komodo's own alerting is configured in the
UI (Settings / Alerters).

### Agent access to Komodo

`desktop/komodo-mcp.yml` runs a read-only MCP server so agent sessions can ask
"is media up?" or "which containers are unhealthy?" without SSH. It runs on the
workstation, publishes its port to `127.0.0.1` only, and reaches Core over the
LAN — it is not part of the general or media deployment and needs no Docker
socket.

Registering it is separate from running it: the stack starts the service, and
Polytoken's global config points at the endpoint.

```yaml
# ~/.config/polytoken/config.yaml
mcp_servers:
  komodo:
    transport: http
    url: http://127.0.0.1:8000/mcp
```

Check the tool surface with `polytoken doctor` (expect the server to report its
tools). Two independent layers keep it read-only: `MCP_AUTH_ENABLED=false` makes
anonymous HTTP callers read-only upstream, and the category allowlist plus
explicit exclusions in `desktop/komodo-mcp.yml` prune the mutating tools out of
the list the model sees. Komodo API keys carry no permissions of their own — a
key is only as narrow as the grants attached to its user, so check what a key
can actually do before relying on it.

## Backups

Each stack runs a `backup` service (`general/backup.yml`, `media/backup.yml`) that
takes a full snapshot of the stack's state once a day at 04:00 local time and
writes `<stack>-backup-<timestamp>.zip` into the Google Drive "Server Backups"
directory (`/mnt/smallHDD/google-drive/Server Backups` on general,
`/bigdisk/google-drive/Server Backups` on media). All protected state is mounted
read-only into the backup container, which therefore needs no docker socket.

What gets backed up is declared in the backup service's `BACKUP_PATHS` /
`BACKUP_VOLUMES` environment. `scripts/tests/backup/tests.sh` cross-references
that list against every other service's resolved mounts, so adding a container
without backup coverage fails `make test` and CI. Mounts deliberately excluded
(media libraries, Frigate recordings, Immich's photo library, regenerable
caches, live database data dirs) are listed in `EXCLUDED_MOUNTS` with reasons in
`media/backup.yml`.

Databases on media are not hot-copied: `postgres-db-dump` (media/postgres.yml)
and `immich-db-dump` (media/immich.yml) export nightly `pg_dumpall` snapshots to
`/bigdisk/db-dumps`, which the backup zips. On general, CouchDB, UniFi's
MongoDB, and Home Assistant's SQLite database are hot-copied (excluding
mid-write SQLite side files); see the CouchDB section below for a consistent
alternative.

Retention is grandfather-father-son: the last 7 daily snapshots, then one per
week for 11 weeks, then one per month for 9 months — 27 restore points. Pruning
runs after each successful backup and only ever touches files matching
`<stack>-backup-*.zip`.

Manual run (e.g. for a stop-first consistent copy of the general databases):

```sh
cd general
docker compose stop couchdb unifi-db
docker compose run --rm backup sh -c 'apk add --no-cache zip >/dev/null && sh /backup.sh --now'
docker compose start couchdb unifi-db
```

Restore: unzip the snapshot (it mirrors the host layout, with named volumes
under `docker-volumes/<volume-name>`), stop the affected services, copy the
state back (re-apply ownership where the service is picky — CouchDB needs
`chown -R 5984:5984 /home/wbw/couchdb`), restore named volumes with
`docker volume create` + copy, and start the services. Each zip contains a
`backup-manifest.txt` declaring exactly what it covers.

Off-box replication is a follow-up: point `rclone move` (or `restic`) at the
"Server Backups" directory once a Google Drive remote is configured.

### Google Drive sync

The `gdrive:` remote (`~/.config/rclone/rclone.conf`) backs two host-level
one-way syncs. Their systemd units live in `systemd/` (not compose services)
and are installed manually — they run on the host, not in containers:

- `rclone-gdrive-sync` — Drive → `/bigdisk/google-drive`, triggered every
  minute. This mirror is how Google Photos reaches immich (`media/immich.yml`
  mounts `Photos/` read-only) and how the backup zips above land on Drive. It
  excludes `Immich Library/`, which is push-only (see below), so the pushed
  mirror isn't copied back onto `/bigdisk`.
- `rclone-immich-push` — all Immich originals
  (`/bigdisk/immich/library/upload/<user-uuid>`, ~1.2 TiB) →
  `gdrive:Immich Library`, daily. Installed but deliberately left disabled:
  the 2 TiB Drive plan has ~1.1 TiB free, short of the full mirror. Once
  Drive space is cleared, enable with
  `sudo systemctl enable --now rclone-immich-push.timer`. The first run takes
  days (Google caps API uploads around 750 GiB/day);
  `--drive-stop-on-upload-limit` ends each run at the cap and the timer
  resumes from there.

Install after cloning or editing:

```sh
cd /home/wbw/docker_files
sudo cp systemd/rclone-gdrive-sync.service systemd/rclone-immich-push.service \
    systemd/rclone-immich-push.timer /etc/systemd/system/
sudo systemctl daemon-reload
```

## CouchDB backup and restore

`/home/wbw/couchdb/data` is the authoritative state (databases and indexes); `/home/wbw/couchdb/etc` holds the `local.d` configuration, including the admin credential hash written on first start. Existing host backups of `/home/wbw` therefore cover CouchDB, with one consistency requirement: a copy taken while the container is running can capture a database mid-write. For a consistent copy, stop the service first:

```sh
cd general && docker compose stop couchdb
# see "Backups" above: docker compose run --rm backup sh -c \
#   'apk add --no-cache zip >/dev/null && sh /backup.sh --now'
docker compose start couchdb
```

To restore: stop the service, restore both directories, re-apply ownership (`chown -R 5984:5984 /home/wbw/couchdb`), and start the service again. Restore `data` and `etc` as a pair so the backup stays self-consistent.

## Mindwtr Cloud deployment

`mindwtr-cloud` runs as UID/GID 1000 and writes its state to `/app/cloud_data`, so the bind-mounted directory must exist and be owned by that ID *before* the first start:

```sh
mkdir -p /home/wbw/mindwtr
chown 1000:1000 /home/wbw/mindwtr
```

Without this the container exits with `cloud data directory is not writable` and restarts in a loop. Set `MINDWTR_CLOUD_AUTH_TOKENS` in `general/.env` (generate with `openssl rand -hex 32`), then bring up the service. It publishes no host port; Nginx Proxy Manager reaches it as `mindwtr-cloud:8787` over the shared `mindwtr-net` network, so the proxy host must use that hostname and must not append `/v1` to the base URL configured in the apps.

The token is the whole account, which drives three consequences worth knowing before deploying:

- **One token, all devices.** The token is hashed to the dataset filename, so devices sync together only by sharing a token. A second token is a second, empty dataset rather than a second key for the same one.
- **Rotation orphans data.** Changing the token and recreating the container leaves the previous dataset on disk under the old token's hash; the new token starts empty. Move `<old-sha256>.json` onto the new key deliberately if you need to keep the data.
- **An unset variable fails closed.** The server refuses to start when no allowlist is configured, so a missing `MINDWTR_CLOUD_AUTH_TOKENS` takes the service down rather than opening the instance to any token.

Each dataset is a single JSON file under `/home/wbw/mindwtr` (`<sha256-of-token>.json`), plus a `.locks` directory used for write serialization. The directory is covered by the general stack's daily backup (`general/backup.yml`), which copies it live; for a guaranteed-consistent copy, stop the service first as described under [Backups](#backups).

## Validation

Validate the complete application model of every stack before deploying:

```sh
make validate
```

This mirrors what CI runs. It copies each stack's `.env.example` into a throwaway
directory as `.env`, then runs `docker compose config --quiet` for every stack in
`STACKS` (`general/`, `media/`, `desktop/`) there — so your real `.env` files are
never touched. All three require env values (`${VAR:?...}`); `make validate`
supplies them from the examples, which is why a bare `cd general && docker compose
config` fails on a fresh checkout without a `.env`.

The repository includes multiple host-specific configurations, so successful
syntax validation does not guarantee that every bind mount, device, credential, or external build context is available on another machine.

## Tests and CI

`scripts/tests/health-notify.sh` logic is covered by a stubbed test suite:

```sh
make test        # run the suite (48 assertions)
make check       # test + validate — what CI runs
```

The suite extracts the real script's functions and runs them against stub
`curl`/`df`/`docker`/`openssl` binaries, so it needs no Docker daemon, no network,
and no secrets. It writes all scratch to a temporary directory and never modifies
the working tree.

GitHub Actions runs both checks on every push and pull request (see
`.github/workflows/ci.yml`): `shell-tests` runs the suite, and `compose-validate`
strictly validates each stack. `make validate` needs the scratch directory it
creates to be readable by the Docker CLI; if Docker is installed as a snap, it
is confined to your home directory, so a `TMPDIR` outside `$HOME` (such as
`/tmp`) fails. The default already works — set `COMPOSE_VALIDATE_TMPDIR` only if
you are redirecting it somewhere under `$HOME`. Note that `docker compose config`
validates
*configuration*, not runtime behavior — it would not catch something like a
crash-looping container. See `.env.example` in each stack directory for the
required variables.
