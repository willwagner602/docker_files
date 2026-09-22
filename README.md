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
| `autoheal.yml` | Autoheal | Watches Docker containers through the Docker socket. |
| `health-notify.yml` | Health notifier | Watches Docker/container state through the Docker socket. |
| `frigate.yml` | Frigate | Independent NVR service. |
| `photo-uploader.yml` | Photo uploader | Uses a persistent SQLite volume plus a read-only photo-library bind mount. |

`media/compose.yaml` is the canonical media-server deployment. It sets the stable project name `media` and includes the component files, so the complete deployment can be managed without `-f` or `-p`. The ARR services remain in one component file because they communicate using Compose service names.

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
| `job-digest.yml` | Job Digest | Independent locally built service. |
| `couchdb.yml` | CouchDB | Self-hosted Obsidian LiveSync backend; behind Nginx Proxy Manager over a dedicated `couchdb-net` Docker network shared only with the proxy, with data bind-mounted under `/home/wbw/couchdb`. |

`general/compose.yaml` is the canonical general-server deployment. It sets the stable project name `general` and includes every service-level compose file. Shared networks retain their fixed names so services from separate files can communicate within the combined deployment.

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

These files use host-specific bind mounts, device mappings, build contexts, and environment variables. Before starting a service:

1. Confirm that the referenced host paths and devices exist. For CouchDB, create the bind-mount directories before the first start and give them to UID 5984, the `couchdb` user inside the container: `mkdir -p /home/wbw/couchdb/{data,etc} && chown -R 5984:5984 /home/wbw/couchdb`. Docker creates missing bind-mount sources as root-owned, which leaves CouchDB unable to write.
2. Provide required variables through an environment file or the shell. Examples include `POSTGRES_PASSWORD`, `SONARR_API_KEY`, `RADARR_API_KEY`, `SAB_API_KEY`, `COUCHDB_USER` and `COUCHDB_PASSWORD` for CouchDB, and the VPN variables used by SABnzbd and qBittorrent. Photo uploader additionally requires `PHOTO_UPLOADER_PHOTO_PATH`, operator credentials, a session secret, a Bluesky handle, and a Bluesky App Password; it stores its SQLite database in the named `photo-uploader-data` volume.
3. Review credentials and secrets before deployment. Some existing service definitions contain deployment-specific values and should be treated as sensitive.
4. Ensure the required Docker networks and host permissions are available.

The Compose files do not create host directories or hardware devices automatically.

## CouchDB backup and restore

`/home/wbw/couchdb/data` is the authoritative state (databases and indexes); `/home/wbw/couchdb/etc` holds the `local.d` configuration, including the admin credential hash written on first start. Existing host backups of `/home/wbw` therefore cover CouchDB, with one consistency requirement: a copy taken while the container is running can capture a database mid-write. For a consistent copy, stop the service first:

```sh
cd general && docker compose stop couchdb
# back up /home/wbw/couchdb with the existing host backup tooling
docker compose start couchdb
```

To restore: stop the service, restore both directories, re-apply ownership (`chown -R 5984:5984 /home/wbw/couchdb`), and start the service again. Restore `data` and `etc` as a pair so the backup stays self-consistent.

## Validation

Validate both complete application models before deploying:

```sh
(cd media && docker compose config --quiet)
(cd general && docker compose config --quiet)
```

The repository includes multiple host-specific configurations, so successful syntax validation does not guarantee that every bind mount, device, credential, or external build context is available on another machine.
