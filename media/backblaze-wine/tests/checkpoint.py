"""Read-only stopped-client recovery checkpoint."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tarfile
import time

import collect

CONFIG = Path('/bigdisk/backblaze-personal/config')
MARKER = Path('/home/wbw/backblaze-overlay-test/drive-root/.bzvol')
COMPOSE = Path(__file__).resolve().parents[1] / 'compose.yaml'
CONTAINER = 'Backblaze64'
MARGIN = 64 * 1024 * 1024


def _inspect():
    p = subprocess.run(['docker', 'inspect', CONTAINER], capture_output=True, check=False)
    if p.returncode:
        raise RuntimeError('docker inspect failed')
    return json.loads(p.stdout)


def _stopped(raw):
    if isinstance(raw, list):
        if len(raw) != 1:
            return False
        raw = raw[0]
    state = raw.get('State', raw.get('state', {}))
    return str(state.get('Status', '')).lower() == 'exited' and state.get('Running') is False


def _walk(root):
    root = Path(root)
    if root.is_symlink() or not root.exists() or not root.is_dir():
        raise ValueError(f'expected directory: {root}')
    yield root
    for p in sorted(root.iterdir(), key=lambda x: x.name):
        s = p.lstat()
        if stat.S_ISLNK(s.st_mode):
            yield p
        elif stat.S_ISREG(s.st_mode):
            yield p
        elif stat.S_ISDIR(s.st_mode):
            yield from _walk(p)
        else:
            raise ValueError(f'special file rejected: {p}')


def _entry(p, root):
    s = p.lstat()
    rel = str(p.relative_to(root))
    item = {'path': rel, 'type': 'symlink' if stat.S_ISLNK(s.st_mode) else
            'directory' if stat.S_ISDIR(s.st_mode) else 'file',
            'mode': stat.S_IMODE(s.st_mode), 'uid': s.st_uid, 'gid': s.st_gid,
            'size': s.st_size}
    if item['type'] == 'file':
        h = hashlib.sha256()
        with p.open('rb') as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b''):
                h.update(chunk)
        item['sha256'] = h.hexdigest()
    elif item['type'] == 'symlink':
        item['target'] = os.readlink(p)
    return item


def _snapshot(roots):
    result = []
    for label, root in roots:
        for p in _walk(root):
            result.append(dict({'root': label}, **_entry(p, root)))
    return result


def _write_json(path, value):
    collect._write(path, (json.dumps(value, indent=2, sort_keys=True) + '\n').encode())


def checkpoint(parent, config=CONFIG, marker=MARKER, compose=COMPOSE,
               docker_inspect=None, mountinfo='/proc/self/mountinfo', margin=MARGIN):
    out = collect._safe_output(parent)
    result = {'kind': 'recovery-checkpoint', 'success': False, 'errors': [],
              'started_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
    try:
        inspect = docker_inspect or _inspect
        before = inspect()
        if not _stopped(before):
            raise RuntimeError('client is not exited and Running=false')
        for p in (Path(config), Path(marker), Path(compose)):
            if p.is_symlink() or not p.exists():
                raise ValueError(f'missing or symlink source: {p}')
        roots = [('config', Path(config)), ('marker', Path(marker))]
        manifest = {'sources': _snapshot(roots), 'compose': _entry(Path(compose), Path(compose).parent)}
        needed = sum(x.get('size', 0) for x in manifest['sources'] if x['type'] == 'file') + Path(compose).stat().st_size + margin
        if shutil.disk_usage(out.parent).free < needed:
            raise OSError('insufficient free space')
        archive = out / 'checkpoint.tar'
        fd = os.open(archive, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(fd)
        with tarfile.open(archive, 'w', format=tarfile.PAX_FORMAT, dereference=False) as tf:
            for label, root in roots:
                for p in _walk(root):
                    tf.add(str(p), arcname=f'{label}/{p.relative_to(root)}', recursive=False)
            tf.add(str(compose), arcname='compose.yaml', recursive=False)
        archive.chmod(0o600)
        with archive.open('rb') as stream:
            manifest['archive_sha256'] = hashlib.file_digest(stream, 'sha256').hexdigest()
        with tarfile.open(archive, 'r') as tf:
            names = {m.name: m for m in tf.getmembers()}
            for item in manifest['sources']:
                m = names.get(f"{item['root']}/{item['path']}")
                if m is None or m.uid != item['uid'] or m.gid != item['gid'] or m.mode != item['mode']:
                    raise ValueError('archive metadata mismatch')
                if item['type'] == 'symlink' and m.linkname != item['target']:
                    raise ValueError('archive symlink mismatch')
                if item['type'] == 'file':
                    with tf.extractfile(m) as stream:
                        h = hashlib.file_digest(stream, 'sha256').hexdigest()
                    if h != item['sha256']:
                        raise ValueError('archive payload mismatch')
            if tf.extractfile(names['compose.yaml']).read() != Path(compose).read_bytes():
                raise ValueError('compose payload mismatch')
        _write_json(out / 'manifest.json', manifest)
        collect._write(out / 'docker-inspect-before.json', json.dumps(before, sort_keys=True).encode())
        collect._write(out / 'host-mountinfo.txt', Path(mountinfo).read_bytes())
        after = inspect()
        if not _stopped(after):
            raise RuntimeError('client state changed during checkpoint')
        collect._write(out / 'docker-inspect-after.json', json.dumps(after, sort_keys=True).encode())
        result.update({'success': True, 'acceptance': 'accepted', 'archive': archive.name})
    except Exception as exc:
        result['errors'].append(type(exc).__name__ + ': ' + str(exc))
        result['acceptance'] = 'blocked'
    result['ended_utc'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    _write_json(out / ('result.json' if not result['success'] else 'summary.json'), result)
    try:
        collect.verify_bundle(out)
    except Exception as exc:
        result['success'] = False
        result['acceptance'] = 'blocked'
        result['errors'].append(type(exc).__name__ + ': ' + str(exc))
    return out, result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--evidence-parent', required=True, type=Path)
    a = ap.parse_args()
    out, result = checkpoint(a.evidence_parent)
    print(json.dumps({'bundle': str(out), 'success': result['success']}))
    return 0 if result['success'] else 1

if __name__ == '__main__':
    raise SystemExit(main())
