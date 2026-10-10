import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import collect


class CollectorTests(unittest.TestCase):
    def test_exclusive_owner_only_bundle(self):
        with tempfile.TemporaryDirectory() as parent:
            a = collect._safe_output(parent)
            b = collect._safe_output(parent)
            self.assertNotEqual(a, b)
            collect._write(a / 'sample', b'private')
            collect.verify_bundle(a)
            with self.assertRaises(FileExistsError):
                collect._write(a / 'sample', b'replacement')
            (a / 'sample').chmod(0o644)
            with self.assertRaises(PermissionError):
                collect.verify_bundle(a)

    def test_bounds(self):
        with tempfile.TemporaryDirectory() as parent:
            p = Path(parent) / 'report'
            p.write_bytes(b'1234')
            self.assertEqual(collect.bounded_file(p, 4), b'1234')
            with self.assertRaises(ValueError):
                collect.bounded_file(p, 3)

    def test_repository_rejected(self):
        with self.assertRaises(ValueError):
            collect._safe_output(collect.REPO)

    def test_partial_capture_never_accepts(self):
        with tempfile.TemporaryDirectory() as parent:
            out = collect._safe_output(parent)
            with patch.object(collect, 'command_capture', side_effect=RuntimeError('failure')):
                result = collect.preflight(out)
            self.assertEqual(result['acceptance'], 'blocked')
            self.assertTrue(result['errors'])
            self.assertIn('stopped-client recovery checkpoint', result['missing'])
            collect.verify_bundle(out)
