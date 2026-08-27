# Docker Compose Services

Docker Compose definitions for the services running on the home server. Each independent service or dependency group has its own Compose file so services can be upgraded, restarted, and deployed without bringing up unrelated containers.

## Repository layout

### `media/plex/`

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
| `docker-compose-health-notify.yml` | Health notifier | Runs independently and watches Docker/container state through the Docker socket. |

The ARR stack shares `/media/plex` on the host, but its container-to-container dependency is the reason those three services remain together. The shared data directory alone does not require a shared Compose project.

### `general/` (unchanged from the original layout)

| Compose file | Services | Why they are grouped |
| --- | --- | --- |
| `docker-compose-unifi.yml` | UniFi Network Application, MongoDB | UniFi uses `unifi-db` as its MongoDB hostname. |
| `docker-compose-nginx-proxy.yml` | Nginx Proxy Manager | Independent service on the shared `npm` Docker network. |
| `docker-compose-wg-easy.yml` | wg-easy | Independent service on the shared `npm` Docker network. |
| `docker-compose-self-update-server.yml` | Self-update server | Independent service on the shared `npm` Docker network. |

The `npm` network is declared with the fixed name `npm` so these separate Compose projects can still communicate when needed. Start the proxy/networked services from the same host where that shared network is available.

### `media/frigate/`

- `media/frigate/docker-compose.yml` contains Frigate and is isolated.

### `media/photo-uploader/`

- `media/photo-uploader/docker-compose.yml` contains the photo uploader. It is independent and uses a persistent SQLite volume plus a read-only photo-library bind mount.

## Running a service

Run a file from the repository root, or change into its directory first:

```sh
docker compose -f media/plex/docker-compose-plex.yml up -d
docker compose -f media/plex/docker-compose-arr.yml up -d
docker compose -f general/docker-compose-unifi.yml up -d
docker compose -f media/frigate/docker-compose.yml up -d
# Requires PHOTO_UPLOADER_PHOTO_PATH and the PHOTO_UPLOADER_* credentials in the environment.
docker compose -f media/photo-uploader/docker-compose.yml up -d
```

To stop or inspect a project, use the same file:

```sh
docker compose -f media/plex/docker-compose-arr.yml ps
docker compose -f media/plex/docker-compose-arr.yml logs -f
docker compose -f media/plex/docker-compose-arr.yml down
```

Run each file as its own Compose project. Do not combine independent files with `-f` unless you intentionally want Compose to merge their service definitions.

## Configuration and host prerequisites

These files use host-specific bind mounts, device mappings, build contexts, and environment variables. Before starting a service:

1. Confirm that the referenced host paths and devices exist.
2. Provide required variables through an environment file or the shell. Examples include `POSTGRES_PASSWORD`, `SONARR_API_KEY`, `RADARR_API_KEY`, `SAB_API_KEY`, and the VPN variables used by SABnzbd and qBittorrent. Photo uploader additionally requires `PHOTO_UPLOADER_PHOTO_PATH`, operator credentials, a session secret, a Bluesky handle, and a Bluesky App Password; it stores its SQLite database in the named `photo-uploader-data` volume.
3. Review credentials and secrets before deployment. Some existing service definitions contain deployment-specific values and should be treated as sensitive.
4. Ensure the required Docker networks and host permissions are available.

The Compose files do not create host directories or hardware devices automatically.

## Validation

Validate a Compose file before deploying:

```sh
docker compose -f media/plex/docker-compose-arr.yml config --quiet
docker compose -f general/docker-compose-unifi.yml config --quiet
```

The repository includes multiple host-specific configurations, so successful syntax validation does not guarantee that every bind mount, device, credential, or external build context is available on another machine.
