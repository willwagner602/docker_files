#!/usr/bin/env python3
"""Opt-in local-only rclone lifecycle experiment; never loads account config."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
from datetime import datetime, timezone


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--allow-local-sync-test', action='store_true', required=True)
    args = parser.parse_args()
    os.umask(0o077)
    bundle = Path(tempfile.mkdtemp(prefix='backblaze-rclone-', dir='/home/wbw'))
    result = {'started_utc': datetime.now(timezone.utc).isoformat(), 'cases': {}}
    binary = '/home/wbw/.local/bin/rclone'
    result['version'] = subprocess.check_output([binary, 'version'], text=True)
    for name, exclude in [('control', False), ('protected', True)]:
        case = bundle / name
        source, dest = case / 'source', case / 'destination'
        source.mkdir(parents=True)
        dest.mkdir()
        (dest / '.bzvol').mkdir()
        (dest / 'unrelated-empty').mkdir()
        (source / 'ordinary.txt').write_text('local disposable test\n')
        # A nested same-name directory must remain in scope.
        (source / 'nested' / '.bzvol').mkdir(parents=True)
        (source / 'nested' / '.bzvol' / 'nested.txt').write_text('nested in scope\n')
        command = [binary, 'sync', str(source), str(dest), '--config=/dev/null',
                   '--fast-list', '--transfers=8', '--checkers=16', '--track-renames',
                   '--create-empty-src-dirs', '--max-delete=500', '--retries=3',
                   '--low-level-retries=10', '--log-level=DEBUG']
        if exclude:
            command += ['--exclude', '/.bzvol/**']
        # Repeated sync validates continued preservation, not just initial creation.
        for iteration in range(2):
            completed = subprocess.run(command, text=True, capture_output=True, timeout=60)
            (case / f'sync-{iteration}.log').write_text(completed.stdout + completed.stderr)
            if completed.returncode:
                raise RuntimeError(f'{name}: local sync failed; evidence: {bundle}')
            assert (dest / '.bzvol').is_dir() == exclude, name
            if exclude:
                assert not list((dest / '.bzvol').iterdir()), 'marker must remain empty'
            assert not (dest / 'unrelated-empty').exists()
            for relative in ['ordinary.txt', 'nested/.bzvol/nested.txt']:
                assert (source / relative).read_bytes() == (dest / relative).read_bytes()
        result['cases'][name] = {'passed': True, 'sync_runs': 2,
                                 'empty_root_marker_preserved': exclude,
                                 'nested_same_name_copied': True,
                                 'unrelated_empty_directory_removed': True}
    result['ended_utc'] = datetime.now(timezone.utc).isoformat()
    (bundle / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    for p in [bundle, *bundle.rglob('*')]:
        assert p.stat().st_uid == os.getuid()
        assert p.stat().st_mode & 0o777 == (0o700 if p.is_dir() else 0o600)
    print(json.dumps({'passed': True, 'evidence': str(bundle), 'cases': result['cases']}))


if __name__ == '__main__':
    main()
