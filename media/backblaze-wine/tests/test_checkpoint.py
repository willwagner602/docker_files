import json
import os
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import checkpoint


class CheckpointTests(unittest.TestCase):
    def fixture(self):
        td = tempfile.TemporaryDirectory()
        root = Path(td.name)
        config = root / 'config'
        (config / 'wine/dosdevices').mkdir(parents=True)
        (config / 'wine/dosdevices/c:').symlink_to('../drive_c')
        (config / 'plain').write_bytes(b'config-data')
        (config / 'plain').chmod(0o640)
        marker = root / 'drive-root/.bzvol'
        marker.mkdir(parents=True)
        (marker / 'bzvol_id.xml').write_bytes(b'<bzvolume>fixture</bzvolume>')
        compose = root / 'compose.yaml'
        compose.write_bytes(b'services: {}\n')
        mountinfo = root / 'mountinfo'
        mountinfo.write_bytes(b'fixture mountinfo\n')
        return td, config, marker, compose, mountinfo

    @staticmethod
    def stopped():
        return [{'State': {'Status': 'exited', 'Running': False}}]

    def test_archive_tree_symlinks_exact_marker_and_permissions(self):
        td, config, marker, compose, mountinfo = self.fixture()
        self.addCleanup(td.cleanup)
        parent_td = tempfile.TemporaryDirectory(); self.addCleanup(parent_td.cleanup)
        with patch.object(checkpoint, '_inspect', return_value=self.stopped()):
            out, result = checkpoint.checkpoint(parent_td.name, config, marker, compose,
                                                mountinfo=mountinfo, margin=0)
        self.assertTrue(result['success'], result)
        self.assertEqual(out.stat().st_mode & 0o777, 0o700)
        for p in out.rglob('*'):
            self.assertEqual(p.stat().st_mode & 0o777, 0o600 if p.is_file() else 0o700)
        with tarfile.open(out / 'checkpoint.tar') as tf:
            self.assertEqual(tf.extractfile('marker/bzvol_id.xml').read(), b'<bzvolume>fixture</bzvolume>')
            link = tf.getmember('config/wine/dosdevices/c:')
            self.assertTrue(link.issym())
            self.assertEqual(link.linkname, '../drive_c')
            self.assertEqual(tf.extractfile('compose.yaml').read(), b'services: {}\n')
        manifest = json.loads((out / 'manifest.json').read_text())
        self.assertTrue(any(x['path'] == 'bzvol_id.xml' for x in manifest['sources']))

    def test_running_client_blocked_and_recorded(self):
        td, config, marker, compose, mountinfo = self.fixture()
        self.addCleanup(td.cleanup)
        running = [{'State': {'Status': 'running', 'Running': True}}]
        parent_td = tempfile.TemporaryDirectory(); self.addCleanup(parent_td.cleanup)
        with patch.object(checkpoint, '_inspect', return_value=running):
            out, result = checkpoint.checkpoint(parent_td.name, config, marker, compose,
                                                mountinfo=mountinfo, margin=0)
        self.assertFalse(result['success'])
        self.assertEqual(result['acceptance'], 'blocked')
        self.assertTrue((out / 'result.json').exists())
        self.assertFalse((out / 'checkpoint.tar').exists())

    def test_after_state_gate_blocks_partial_success(self):
        td, config, marker, compose, mountinfo = self.fixture()
        self.addCleanup(td.cleanup)
        states = iter([self.stopped(), [{'State': {'Status': 'running', 'Running': True}}]])
        with tempfile.TemporaryDirectory() as parent, patch.object(checkpoint, '_inspect', side_effect=lambda: next(states)):
            out, result = checkpoint.checkpoint(parent, config, marker, compose,
                                                mountinfo=mountinfo, margin=0)
        self.assertFalse(result['success'])
        self.assertEqual(result['acceptance'], 'blocked')
        self.assertTrue(result['errors'])


if __name__ == '__main__':
    unittest.main()
