import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

import collect
import source_inventory


class SourceInventoryTests(unittest.TestCase):
    def test_metadata_categories_and_symlink_not_followed(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); (root / 'dir').mkdir(); (root / 'file').write_bytes(b'abc')
            (root / 'link').symlink_to(root / 'file')
            result = source_inventory.inventory_root(root, runner=lambda *a, **k: type('P', (), {'returncode': 1, 'stdout': ''})())
            by_path = {r['path']: r for r in result['records']}
            self.assertEqual(by_path['dir']['type'], 'directory')
            self.assertEqual(by_path['file']['type'], 'regular')
            self.assertEqual(by_path['link']['type'], 'symlink_unsupported')
            self.assertEqual(by_path['file']['size'], 3)
            self.assertIn('subvolumes', result)
            self.assertEqual(result['subvolumes']['status'], 'unavailable')

    def test_bzvol_absent_symlink_and_nonempty_block(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / '.bzvol').mkdir(); (root / '.bzvol' / 'x').touch()
            with self.assertRaises(ValueError): source_inventory.inventory_root(root)
            (root / '.bzvol' / 'x').unlink(); (root / '.bzvol').rmdir()
            (root / '.bzvol').symlink_to(root)
            with self.assertRaises(ValueError): source_inventory.inventory_root(root)

    def test_bundle_is_private_and_summary_has_counts_only(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / 'source'; root.mkdir(); (root / 'x').write_text('secret-name')
            with patch.object(source_inventory, 'SOURCES', (root,)):
                bundle, summary = source_inventory.write_inventory(Path(td))
            self.assertEqual(stat.S_IMODE((bundle / 'source-inventory.jsonl').stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE((bundle / 'summary.json').stat().st_mode), 0o600)
            self.assertEqual(summary['counts']['regular'], 1)
            self.assertNotIn('secret-name', (bundle / 'summary.json').read_text())
            collect.verify_bundle(bundle)

    def test_subvolume_command_failure_is_unavailable(self):
        def fail(argv, **kwargs):
            raise OSError('missing')
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); result = source_inventory.inventory_root(root, runner=fail)
            self.assertEqual(result['subvolumes']['status'], 'unavailable')
            self.assertEqual(result['mounts']['status'], 'unavailable')


if __name__ == '__main__': unittest.main()
