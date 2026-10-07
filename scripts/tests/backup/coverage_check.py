#!/usr/bin/env python3
"""Coverage check for a compose stack's backup service.

Usage: coverage_check.py <compose-config.json> <stack-name>

Reads the resolved `docker compose config --format json` output and verifies,
against the backup service's own environment (the single source of truth):

  1. A service named `backup` exists and declares the required variables.
  2. Every bind mount of every other service is either inside some
     BACKUP_PATHS entry or explicitly listed in EXCLUDED_MOUNTS.
  3. Every named volume mounted by any service is listed in BACKUP_VOLUMES,
     and every BACKUP_VOLUMES entry is a volume the stack actually declares.
  4. Every BACKUP_PATHS entry is an existing mount (equal to or containing a
     bind mount source) or is whitelisted in EXTRA_BACKUP_PATHS.
  5. The backup service actually mounts what it declares: one read-only mount
     per path at /backup-roots<path>, one per volume at
     /volume-roots/<volume>, plus the DEST_DIR mount at /backups.

Exits non-zero and prints each gap if anything is uncovered.
"""

import json
import sys

cfg = json.load(open(sys.argv[1]))
stack = sys.argv[2]
# When the suite resolves compose config from a throwaway copy, relative
# mounts (../scripts/...) point into the temp dir; map them back to the
# canonical deployment path.
temp_prefix = sys.argv[3] if len(sys.argv) > 3 else ""


def norm(p):
    if temp_prefix and p.startswith(temp_prefix):
        p = "/home/wbw/docker_files" + p[len(temp_prefix):]
    return p.rstrip("/") if len(p) > 1 else p

services = cfg.get("services", {})
volumes = cfg.get("volumes", {})
problems: list[str] = []


def env_of(service):
    raw = service.get("environment") or []
    env = {}
    if isinstance(raw, dict):
        return {k: v or "" for k, v in raw.items()}
    for item in raw:
        if "=" in item:
            k, _, v = item.partition("=")
            env[k] = v
    return env


backup = services.get("backup")
if backup is None:
    print(f"{stack}: no `backup` service found")
    sys.exit(1)
env = env_of(backup)

required = [
    "ROLE",
    "DEST_DIR",
    "BACKUP_AT",
    "KEEP_DAILY",
    "KEEP_WEEKLY",
    "KEEP_MONTHLY",
    "BACKUP_PATHS",
    "EXCLUDED_MOUNTS",
    "EXTRA_BACKUP_PATHS",
]
for key in required:
    if key not in env:
        problems.append(f"backup service is missing required env var {key}")
if "BACKUP_VOLUMES" not in env:
    problems.append("backup service is missing required env var BACKUP_VOLUMES")
if problems:
    for p in problems:
        print(f"  {stack}: {p}")
    sys.exit(1)

paths = [norm(p) for p in env["BACKUP_PATHS"].split()]
vols = env["BACKUP_VOLUMES"].split()
excluded = [norm(p) for p in env["EXCLUDED_MOUNTS"].split()]
extras = [norm(p) for p in env["EXTRA_BACKUP_PATHS"].split()]

bind_mounts = {}  # service -> list of sources
volume_mounts = {}
for name, svc in sorted(services.items()):
    if name == "backup":
        continue
    for v in svc.get("volumes") or []:
        src = norm(v.get("source", ""))
        if v.get("type", "bind") == "volume":
            volume_mounts.setdefault(name, []).append(src)
        else:
            bind_mounts.setdefault(name, []).append(src)

all_binds = {s for srcs in bind_mounts.values() for s in srcs}
all_vols = {s for srcs in volume_mounts.values() for s in srcs}


def covered_by_paths(src):
    return any(src == p or src.startswith(p + "/") for p in paths)


def excluded_by_paths(src):
    return any(src == e or src.startswith(e + "/") for e in excluded)


def path_covers_mount(p):
    return any(p == s or s.startswith(p + "/") for s in all_binds)


# 2. every bind mount covered or explicitly excluded
for svc, srcs in sorted(bind_mounts.items()):
    for src in srcs:
        if covered_by_paths(src) or excluded_by_paths(src):
            continue
        problems.append(
            f"service {svc} mounts {src} which is in neither BACKUP_PATHS nor EXCLUDED_MOUNTS"
        )

# 3a. every mounted volume is declared for backup
for svc, srcs in sorted(volume_mounts.items()):
    for src in srcs:
        if src not in vols:
            problems.append(f"service {svc} uses volume {src} which is not in BACKUP_VOLUMES")
# 3b. every declared backup volume exists in the stack
for v in vols:
    if v not in volumes:
        problems.append(f"BACKUP_VOLUMES lists {v} which the {stack} stack does not declare")

# 4. every backup path is justified
for p in paths:
    if path_covers_mount(p) or p in extras:
        continue
    problems.append(
        f"BACKUP_PATHS lists {p} which no service mounts and is not in EXTRA_BACKUP_PATHS"
    )

# 5. the backup service mounts what it declares
backup_mounts = backup.get("volumes") or []
backup_bind_targets = {
    v.get("target"): v for v in backup_mounts if v.get("type", "bind") == "bind"
}
backup_vol_targets = {
    v.get("source"): v for v in backup_mounts if v.get("type") == "volume"
}
for p in paths:
    want = "/backup-roots" + p
    m = backup_bind_targets.get(want)
    if m is None:
        problems.append(f"backup service does not mount {p} at {want}")
    elif not m.get("read_only"):
        problems.append(f"backup service mount for {p} is not read-only")
for v in vols:
    m = backup_vol_targets.get(v)
    if m is None:
        problems.append(f"backup service does not mount volume {v} at /volume-roots/{v}")
    elif not m.get("read_only"):
        problems.append(f"backup service volume mount {v} is not read-only")
if "/backups" not in backup_bind_targets:
    problems.append("backup service does not mount DEST_DIR at /backups")

if problems:
    for p in problems:
        print(f"  {stack}: {p}")
    sys.exit(1)
