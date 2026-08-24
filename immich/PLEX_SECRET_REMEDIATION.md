# Separate Plex credential remediation runbook

**Status:** unresolved; separate from Immich deployment.
**Owner:** Plex/media-host operator (assign before merge).
**Scope:** revoke/rotate credentials exposed by the existing Plex stack and move all secrets to host-only injection. Do not silently modify `plex/docker-compose.yml` as part of Immich deployment.

## Inventory

The current repository contains a literal `PLEX_CLAIM` value in `plex/docker-compose.yml`. Treat it as compromised. Search the repository and target host for:

```sh
git grep -nE 'PLEX_CLAIM|POSTGRES_PASSWORD|TELEGRAM|[A-Za-z0-9_]*API_KEY' -- .
sudo grep -RInE 'PLEX_CLAIM|POSTGRES_PASSWORD|TELEGRAM|[A-Za-z0-9_]*API_KEY' /opt /home 2>/dev/null
```

Review `plex/docker-compose.yml`, `plex/.env.example`, host-only `plex/.env`, container inspect output, CI variables, shell history, and any backups. Do not print secret values into tickets or reports.

## Target-host actions

1. Sign in to the Plex account, revoke the exposed claim/token if still valid, and issue a replacement only through the Plex-supported account flow.
2. Rotate every discovered database password, Telegram token/chat identifier, Sonarr/Radarr/other `*_API_KEY`, and any related credential. Revoke old API keys where the service supports revocation.
3. Create a root-owned, mode-0600 host environment file outside Git, for example `/opt/plex/.env`, and populate it interactively. Use a tracked template containing names only.
4. Replace literal values in the Plex Compose configuration with `${PLEX_CLAIM}`, `${POSTGRES_PASSWORD}`, `${TELEGRAM_*}`, and `${*_API_KEY}` references, or use an equivalent host-only `env_file` mechanism. Do not put replacement values in the repository.
5. Before restarting, render with `docker compose -p plex config` while preventing rendered output from being logged or committed. Verify no secret literal remains in tracked files.
6. Restart only the Plex project, verify Plex/Ombi/Sonarr/Radarr/Frigate behavior, and inspect bounded logs for authentication failures.
7. Invalidate old credentials, remove them from shell history/tickets/backups where practical, and document rotation dates without values.

Example host-only setup (adapt paths to the actual Plex deployment):

```sh
sudo install -d -m 700 /opt/plex
sudo install -o root -g root -m 600 /dev/null /opt/plex/.env
sudoedit /opt/plex/.env
cd /path/to/plex
sudo docker compose --env-file /opt/plex/.env -p plex config --quiet
sudo docker compose --env-file /opt/plex/.env -p plex up -d
```

Do not run these commands until the operator has reviewed the actual Plex Compose file, service names, and host paths. Keep Plex/Ombi PostgreSQL storage separate from Immich.

## Exit criteria

This runbook remains **unresolved** until an owner records the rotation/revocation date, confirms all inventory categories were checked, confirms no literal secret remains tracked, confirms host-only injection, and records post-rotation service verification. `.gitignore` does not remediate already tracked secrets.
