# Docker Compose Services

Docker Compose definitions for the services running on the home & media servers. Each independent service or dependency group has its own Compose file so services can be upgraded, restarted, and deployed without bringing up unrelated containers.

## Repository layout

### `media/`

| Compose file | Services | Why they are grouped |
| --- | --- | --- |
| `docker-compose-arr.yml` | Sonarr, Radarr, Unpackerr | Unpackerr connects to Sonarr and Radarr using their Compose service names. |
| `docker-compose-plex.yml` | Plex | Independent media server. |
| `docker-compose-ombi.yml` | Ombi | Independent request-management service. |
| `docker-compose-prowlarr.yml` | Prowlarr | Independent indexer manager. |
| `docker-compose-flaresolverr.yml` | FlareSolverr | Independent proxy/solver service. |
| `docker-compose-sabnzbd.yml` | SABnzbd | Independent download service. |
| `docker-compose-qbittorrent.yml` | qBittorrent | Independent download service. |
| `docker-compose-postgres.yml` | PostgreSQL | Separate database service. |
| `docker-compose-autoheal.yml` | Autoheal | Watches Docker containers through the Docker socket. |
| `docker-compose-health-notify.yml` | Health notifier | Watches Docker/container state through the Docker socket. |
| `docker-compose-frigate.yml` | Frigate | Independent NVR service. |
| `docker-compose-photo-uploader.yml` | Photo uploader | Uses a persistent SQLite volume plus a read-only photo-library bind mount. |

`media/compose.yaml` is the canonical media-server deployment. It sets the stable project name `media` and includes the component files, so the complete deployment can be managed without `-f` or `-p`. Docker Compose 2.20.3 or newer is required for `include`. The ARR services remain in one component file because they communicate using Compose service names.

### `general/` (unchanged from the original layout)

| Compose file | Services | Why they are grouped |
| --- | --- | --- |
| `docker-compose-unifi.yml` | UniFi Network Application, MongoDB | UniFi uses `unifi-db` as its MongoDB hostname. |
| `docker-compose-nginx-proxy.yml` | Nginx Proxy Manager | Independent service on the shared `npm` Docker network. |
| `docker-compose-wg-easy.yml` | wg-easy | Independent service on the shared `npm` Docker network. |
| `docker-compose-self-update-server.yml` | Self-update server | Independent service on the shared `npm` Docker network. |

The `npm` network is declared with the fixed name `npm` so these separate Compose projects can still communicate when needed. Start the proxy/networked services from the same host where that shared network is available.

## Running a service

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

General-server services remain independently managed by file, for example:

```sh
docker compose -f general/docker-compose-unifi.yml up -d
```

## Configuration and host prerequisites

These files use host-specific bind mounts, device mappings, build contexts, and environment variables. Before starting a service:

1. Confirm that the referenced host paths and devices exist.
2. Provide required variables through an environment file or the shell. Examples include `POSTGRES_PASSWORD`, `SONARR_API_KEY`, `RADARR_API_KEY`, `SAB_API_KEY`, and the VPN variables used by SABnzbd and qBittorrent. Photo uploader additionally requires `PHOTO_UPLOADER_PHOTO_PATH`, operator credentials, a session secret, a Bluesky handle, and a Bluesky App Password; it stores its SQLite database in the named `photo-uploader-data` volume.
3. Review credentials and secrets before deployment. Some existing service definitions contain deployment-specific values and should be treated as sensitive.
4. Ensure the required Docker networks and host permissions are available.

The Compose files do not create host directories or hardware devices automatically.

## Validation

Validate the complete media model and individual general-server files before deploying:

```sh
(cd media && docker compose config --quiet)
docker compose -f general/docker-compose-unifi.yml config --quiet
```

The repository includes multiple host-specific configurations, so successful syntax validation does not guarantee that every bind mount, device, credential, or external build context is available on another machine.
