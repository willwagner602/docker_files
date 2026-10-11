import os, tempfile, unittest
from pathlib import Path
from evidence import BLOCKED, NormalizedEvidence, parse_evidence

class EvidenceTests(unittest.TestCase):
    def setUp(self): self.td=tempfile.TemporaryDirectory(); self.root=Path(self.td.name)
    def tearDown(self): self.td.cleanup()
    def test_parse_always_blocked_and_empty(self):
        (self.root/'report').write_text('successful\n')
        e=parse_evidence(self.root)
        self.assertTrue(e.blocked); self.assertEqual(e.errors,[BLOCKED])
        self.assertFalse(e.indexed or e.transmitted or e.excluded_with_rule)
    def test_no_false_success_substrings(self):
        (self.root/'report').write_text('not successful; completed scan unknown')
        e=parse_evidence(self.root)
        self.assertEqual(e.errors,[BLOCKED]); self.assertFalse(e.transmitted)
    def test_normalized_requires_timestamps_and_manifest(self):
        with self.assertRaises(ValueError): NormalizedEvidence(None,None,{'a'},set()).reconcile()
        with self.assertRaises(ValueError): NormalizedEvidence(2,1,{'a'},set()).reconcile()
        with self.assertRaises(ValueError): NormalizedEvidence(1,2,set(),{'a'}).reconcile()
    def test_normalized_reconciliation_requires_rule_for_exclusion(self):
        n=NormalizedEvidence(1,2,{'a','b','c'},{'a'},{'b':'rule-id'}) .reconcile()
        self.assertEqual(n.pending,set()); self.assertEqual(n.unexplained,{'c'})
        for rules in ({'outside': 'rule'}, {'b': ''}):
            with self.assertRaises(ValueError):
                NormalizedEvidence(1,2,{'a','b'},set(),rules).reconcile()
        with self.assertRaises(ValueError):
            NormalizedEvidence(1,2,{'a'},{'a'},pending={'a'}).reconcile()
        n = NormalizedEvidence(1,2,{'a'},set(),pending={'a'}).reconcile()
        self.assertEqual(n.pending, {'a'}); self.assertFalse(n.unexplained)
    def test_source_inventory_categories(self):
        (self.root/'d').mkdir(); (self.root/'f').write_text('x'); (self.root/'link').symlink_to(self.root/'f')
        e=parse_evidence(self.root)
        self.assertIn('f',e.inventory['regular']); self.assertIn('d',e.inventory['dir']); self.assertIn('link',e.inventory['symlink'])
        self.assertTrue(e.inventory['subvolume']); self.assertIn('unreadable',e.inventory); self.assertIn('error',e.inventory); self.assertIn('mount',e.inventory)
    def test_absent_root_records_error_and_subvolume_unavailable(self):
        e=parse_evidence(self.root/'missing'); self.assertTrue(e.inventory['error']); self.assertTrue(e.inventory['subvolume'])

if __name__ == '__main__': unittest.main()
