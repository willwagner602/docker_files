#!/usr/bin/env python3
"""Explicit, isolated Docker bind semantics probes. Never touches the live client."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid

IMAGE = 'ghcr.io/iamfoz/backblaze-personal-wine:latest@sha256:539ddfee2bfa0202801f799bac753a679f664986bc8ad9fd6b3ab94957b95d60'


def bind(source, target, readonly):
    return {'type': 'bind', 'source': str(source), 'target': target,
            'read_only': readonly, 'bind': {'create_host_path': False}}


def fixture_override(source, marker):
    return {'services': {'backblaze-wine': {'volumes': [
        bind(source, '/drive_f', True), bind(marker, '/drive_f/.bzvol', False)]}}}


def run(*args):
    return subprocess.run(args, text=True, capture_output=True, check=False)


def test_missing_source_rejected(bundle):
    """Use a unique project and both absent bind paths; never accept an old container."""
    token = 'bz-missing-' + uuid.uuid4().hex
    parent = bundle / token
    parent.mkdir(mode=0o700)
    source, marker = parent / 'absent-source', parent / 'absent-marker'
    config = parent / 'compose.json'
    config.write_text(json.dumps({'services': {'probe': {
        'image': IMAGE, 'entrypoint': ['/bin/true'],
        'volumes': [bind(source, '/drive_f', True),
                    bind(marker, '/drive_f/.bzvol', False)]}}}))
    config.chmod(0o600)
    base = ('docker', 'compose', '-p', token, '-f', str(config))
    if run(*base, 'ps', '-aq').stdout.strip():
        raise RuntimeError('unexpected pre-existing project')
    try:
        result = run(*base, 'up', '--no-start', '--pull', 'never')
        # Some engines defer bind validation until start.
        if result.returncode == 0:
            result = run(*base, 'start')
        raw = parent / 'startup.txt'
        raw.write_text(result.stdout + result.stderr)
        raw.chmod(0o600)
        if result.returncode == 0 or source.exists() or marker.exists():
            raise RuntimeError('missing source was accepted or host paths created')
        if 'bind' not in result.stderr.lower() or 'exist' not in result.stderr.lower():
            raise RuntimeError('startup failed for an unrelated reason; inspect restricted report')
        return {'test_missing_source_rejected': 'passed', 'project': token}
    finally:
        cleaned = run(*base, 'down', '--remove-orphans')
        if cleaned.returncode or run(*base, 'ps', '-aq').stdout.strip():
            raise RuntimeError('disposable project cleanup failed')


class StaticTests(unittest.TestCase):
    def test_compose_mount_contract(self):
        # This tests the proposed fixture contract, NOT the unmigrated live compose.
        config = fixture_override('/fixture', '/marker')
        mounts = config['services']['backblaze-wine']['volumes']
        self.assertEqual([m['target'] for m in mounts], ['/drive_f', '/drive_f/.bzvol'])
        self.assertEqual([m['read_only'] for m in mounts], [True, False])
        self.assertTrue(all(m['bind']['create_host_path'] is False for m in mounts))
        self.assertEqual(set(config['services']['backblaze-wine']), {'volumes'})


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--allow-disposable-docker-test', action='store_true', required=True)
    parser.add_argument('--evidence-parent', type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    parent = args.evidence_parent.resolve(strict=True)
    repo = Path(__file__).resolve().parents[3]
    if parent == Path('/bigdisk') or Path('/bigdisk') in parent.parents or parent == repo or repo in parent.parents:
        parser.error('evidence must be outside repository and backup trees')
    bundle = Path(tempfile.mkdtemp(prefix='backblaze-runtime-', dir=parent))
    bundle.chmod(0o700)
    result = test_missing_source_rejected(bundle)
    (bundle / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    for path in bundle.rglob('*'):
        expected = 0o700 if path.is_dir() else 0o600
        if path.stat().st_uid != os.getuid() or path.stat().st_mode & 0o777 != expected:
            raise RuntimeError('evidence permission mismatch')
    print(json.dumps({'result': result, 'evidence': str(bundle)}))
