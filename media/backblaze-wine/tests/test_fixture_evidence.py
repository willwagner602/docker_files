import json, tempfile, unittest
from pathlib import Path
from fixture_evidence import parse_bundle

class FixtureEvidenceTests(unittest.TestCase):
    def test_absent_root_blocks(self):
        self.assertTrue(parse_bundle('/tmp/does-not-exist-fixture-evidence').blocked)

    def test_nested_absent_capture_blocks(self):
        with tempfile.TemporaryDirectory() as d:
            r=Path(d); (r/'fixture-manifest.json').write_text(json.dumps({'files': {'x.txt': {'size': 1}}}))
            (r/'summary.json').write_text(json.dumps({'created_utc':'2026-10-09T18:30:00Z'}))
            self.assertTrue(parse_bundle(r, capture='nested/missing').blocked)

    def test_malformed_wrong_drive_and_empty_manifest_block(self):
        with tempfile.TemporaryDirectory() as d:
            r=Path(d); (r/'fixture-manifest.json').write_text(json.dumps({'files': {}}))
            u=r/'upload-check-20261009T183044Z'; u.mkdir()
            (u/'v_f____filelist.dat').write_text('# GmtMillisThisListWasStarted: x, GmtDateTime: bad\nf\tbad\t1\tD:\\x.txt\n')
            e=parse_bundle(r); self.assertTrue(e.blocked); self.assertTrue(any('malformed' in x or 'empty' in x for x in e.errors))

    def test_duplicate_conflict_blocks(self):
        with tempfile.TemporaryDirectory() as d:
            r=Path(d); (r/'fixture-manifest.json').write_text(json.dumps({'files': {'x.txt': {'size': 1}}}))
            u=r/'upload-check-20261009T183044Z'; u.mkdir()
            p='F:\\x.txt'; body='# GmtMillisThisListWasStarted: x, GmtDateTime: 20261009183044\n' + f'f\t0000000000000001\t1\t{p}\nf\t0000000000000001\t2\t{p}\n'
            (u/'v_f____filelist.dat').write_text(body); (u/'filestats.xml').write_text('<filestats><progress totally_final="true"/><info datetime="20261009183044"/></filestats>')
            e=parse_bundle(r); self.assertTrue(e.blocked); self.assertTrue(any('duplicate' in x for x in e.errors))

if __name__ == '__main__': unittest.main()
