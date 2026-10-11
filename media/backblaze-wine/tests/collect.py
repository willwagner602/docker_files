"""Restricted read-only preflight capture. Recovery checkpoint is not implemented.

This tool never stops, starts, or executes commands inside the client container.
Raw reports contain private mount paths and environment settings: do not commit.
"""
import argparse
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[3]
MAX_CAPTURE = 8 * 1024 * 1024


def utc():
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())


def _safe_output(parent):
    parent = Path(parent).resolve(strict=True)
    for forbidden in (REPO, Path('/bigdisk'), Path('/home/wbw/backblaze-overlay-test'),
                      Path('/home/wbw/backblaze-drive-markers')):
        if parent == forbidden or forbidden in parent.parents:
            raise ValueError('bundle must be outside repository and backup source trees')
    old = os.umask(0o077)
    try:
        return Path(tempfile.mkdtemp(prefix='backblaze-evidence-', dir=parent))
    finally:
        os.umask(old)


def verify_bundle(out):
    for p in [out, *out.rglob('*')]:
        s = p.lstat()
        mode = 0o700 if stat.S_ISDIR(s.st_mode) else 0o600
        if (s.st_uid != os.getuid() or stat.S_IMODE(s.st_mode) != mode
                or not (stat.S_ISDIR(s.st_mode) or stat.S_ISREG(s.st_mode))):
            raise PermissionError('unsafe evidence ownership/type/mode')


def _write(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as f:
        f.write(data)


def bounded_file(path, limit=MAX_CAPTURE):
    p = Path(path)
    if p.is_symlink() or not p.is_file():
        raise ValueError('not a regular file')
    with p.open('rb') as f:
        data = f.read(limit + 1)
    if len(data) > limit:
        raise ValueError('capture exceeds limit')
    return data


def command_capture(argv, limit=MAX_CAPTURE):
    # Spool to temporary files rather than accumulating unlimited pipe output.
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        p = subprocess.run(argv, stdout=stdout, stderr=stderr, timeout=30, check=False)
        stdout.seek(0); stderr.seek(0)
        data, errors = stdout.read(limit + 1), stderr.read(limit + 1)
    if len(data) > limit or len(errors) > limit:
        raise ValueError('command output exceeds limit')
    if p.returncode:
        raise RuntimeError('capture command failed')
    return data


def preflight(out):
    result = {'started_utc': utc(), 'kind': 'partial-preflight', 'errors': [],
              'acceptance': 'blocked', 'missing': [
                  'stopped-client recovery checkpoint', 'runtime container mountinfo',
                  'authoritative selection flags', 'completed scan and upload correlation']}
    captures = {
        'host-mountinfo.txt': lambda: bounded_file('/proc/self/mountinfo'),
        'docker-inspect.json': lambda: command_capture(['docker', 'inspect', 'Backblaze64']),
        'drive-mappings.json': lambda: json.dumps({
            p.name: os.readlink(p) for p in
            Path('/bigdisk/backblaze-personal/config/wine/dosdevices').iterdir()
            if p.is_symlink()}, sort_keys=True).encode(),
    }
    for name, collect in captures.items():
        try:
            _write(out / name, collect())
        except Exception as e:
            result['errors'].append(name + ': ' + type(e).__name__)
    result['ended_utc'] = utc()
    _write(out / 'summary.json', json.dumps(result, indent=2).encode())
    verify_bundle(out)
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('command', choices=['preflight'])
    ap.add_argument('--evidence-parent', required=True, type=Path)
    a = ap.parse_args()
    out = _safe_output(a.evidence_parent)
    result = preflight(out)
    print(json.dumps({'bundle': str(out), 'errors': result['errors'], 'acceptance': 'blocked'}))
    return 1 if result['errors'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
