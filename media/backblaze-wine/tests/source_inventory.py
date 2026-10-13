"""Read-only metadata inventory for backup source trees."""
import argparse
import json
import os
from pathlib import Path
import stat
import subprocess
import time

import collect

SOURCES = (Path('/bigdisk/google-drive'), Path('/bigdisk/immich/library/upload/ffb64a21-1742-43ee-aeb0-4e54c488de9c'))


def _utc():
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())


def _rel(path, root):
    return os.path.relpath(str(path), str(root))


def _root_check(root):
    marker = root / '.bzvol'
    if marker.is_symlink():
        raise ValueError(f'{root}: .bzvol is a symlink')
    if marker.exists():
        if marker.is_dir() and any(marker.iterdir()):
            raise ValueError(f'{root}: .bzvol is non-empty')
        raise ValueError(f'{root}: .bzvol must be absent')


def _metadata(path, root, kind):
    s = os.lstat(path)
    return {'path': _rel(path, root), 'type': kind, 'size': s.st_size,
            'mtime_ns': s.st_mtime_ns, 'mode': stat.S_IMODE(s.st_mode),
            'uid': s.st_uid, 'gid': s.st_gid,
            'readable_uid1000': os.access(path, os.R_OK, effective_ids=False)}


def _probe_mounts(root, runner=subprocess.run):
    try:
        p = runner(['findmnt', '-R', '-T', str(root), '-n', '-o', 'TARGET,SOURCE,FSTYPE'],
                   text=True, capture_output=True, check=False, timeout=30)
        if p.returncode:
            return {'status': 'error', 'count': 0}
        return {'status': 'ok', 'count': sum(bool(x.strip()) for x in p.stdout.splitlines())}
    except (OSError, subprocess.SubprocessError):
        return {'status': 'unavailable', 'count': 0}


def _probe_subvolumes(root, runner=subprocess.run):
    try:
        p = runner(['btrfs', 'subvolume', 'list', '-o', str(root)],
                   text=True, capture_output=True, check=False, timeout=30)
        if p.returncode:
            return {'status': 'unavailable', 'count': 0}
        return {'status': 'ok', 'count': sum(bool(x.strip()) for x in p.stdout.splitlines())}
    except (OSError, subprocess.SubprocessError):
        return {'status': 'unavailable', 'count': 0}


def inventory_root(root, runner=subprocess.run, stat_fn=os.lstat):
    root = Path(root)
    _root_check(root)
    records, errors, counts = [], [], {}
    def onerror(exc):
        errors.append({'path': _rel(getattr(exc, 'filename', root), root), 'error': type(exc).__name__})
    try:
        root_stat = stat_fn(root)
    except OSError as exc:
        return {'root': str(root), 'records': [], 'errors': [{'path': '.', 'error': type(exc).__name__}], 'counts': {'errors': 1}, 'mounts': _probe_mounts(root, runner), 'subvolumes': _probe_subvolumes(root, runner)}
    for directory, dirs, files in os.walk(root, topdown=True, followlinks=False, onerror=onerror):
        names = list(dirs) + list(files)
        for name in names:
            path = Path(directory) / name
            rel = _rel(path, root)
            try:
                s = stat_fn(path)
                mode = s.st_mode
                if stat.S_ISLNK(mode): kind = 'symlink_unsupported'
                elif stat.S_ISDIR(mode): kind = 'directory'
                elif stat.S_ISREG(mode): kind = 'regular'
                else: kind = 'special'
                rec = _metadata(path, root, kind)
                # st_ino==256 is only a candidate; never claim a subvolume from it.
                rec['subvolume_candidate'] = (s.st_ino == 256)
                records.append(rec); counts[kind] = counts.get(kind, 0) + 1
            except PermissionError:
                records.append({'path': rel, 'type': 'unreadable'}); counts['unreadable'] = counts.get('unreadable', 0) + 1
            except OSError as exc:
                errors.append({'path': rel, 'error': type(exc).__name__}); counts['errors'] = counts.get('errors', 0) + 1
    return {'root': str(root), 'records': records, 'errors': errors, 'counts': counts,
            'mounts': _probe_mounts(root, runner), 'subvolumes': _probe_subvolumes(root, runner)}


def write_inventory(parent, roots=None):
    if roots is None:
        roots = SOURCES
    out = collect._safe_output(parent)
    started = _utc(); all_errors = []; counts = {}; mounts = []; subvolumes = []
    stream = out / 'source-inventory.jsonl'
    fd = os.open(stream, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        for root in roots:
            try: result = inventory_root(root)
            except Exception as exc:
                all_errors.append({'root': str(root), 'error': type(exc).__name__}); continue
            for record in result['records']:
                f.write(json.dumps({'root': str(root), **record}, sort_keys=True) + '\n')
            all_errors.extend({'root': str(root), **e} for e in result['errors'])
            for key, value in result['counts'].items(): counts[key] = counts.get(key, 0) + value
            mounts.append(result['mounts']); subvolumes.append(result['subvolumes'])
    summary = {'kind': 'source-inventory', 'started_utc': started, 'ended_utc': _utc(),
               'counts': counts, 'errors': len(all_errors), 'mounts': mounts,
               'subvolumes': subvolumes, 'limitations': ['metadata only; no content hashing', 'subvolume boundaries require successful btrfs command']}
    collect._write(out / 'errors.json', json.dumps(all_errors, sort_keys=True).encode())
    collect._write(out / 'summary.json', json.dumps(summary, sort_keys=True).encode())
    collect.verify_bundle(out)
    return out, summary


if __name__ == '__main__':
    ap = argparse.ArgumentParser(); ap.add_argument('--evidence-parent', required=True, type=Path)
    args = ap.parse_args(); bundle, summary = write_inventory(args.evidence_parent)
    print(json.dumps({'bundle': str(bundle), 'counts': summary['counts'], 'errors': summary['errors']}))
