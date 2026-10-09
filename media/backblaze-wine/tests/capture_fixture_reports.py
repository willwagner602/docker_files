"""Capture bounded raw fixture reports. Observations are not automatic acceptance."""
import argparse
import datetime
import json
import os
from pathlib import Path
import xml.etree.ElementTree as ET
from collect import _write, bounded_file, verify_bundle


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('bundle', type=Path)
    args = ap.parse_args()
    os.umask(0o077)
    verify_bundle(args.bundle)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    out = args.bundle / ('upload-check-' + stamp)
    out.mkdir(mode=0o700)
    base = Path('/bigdisk/backblaze-personal/config/wine/drive_c/ProgramData/Backblaze/bzdata')
    manifest = json.loads((args.bundle / 'fixture-manifest.json').read_text())
    expected = {'F:\\' + p.replace('/', '\\') for p in manifest['files']}
    sources = list((base / 'bzfilelists').glob('*_f____filelist.dat'))
    sources += [base / p for p in ['bzfilelists/filestats.xml',
        'bzreports/bzhost_testimony_x.xml', 'bzlogs/bzreports_lastfilestransmitted/09.log',
        'bzlogs/bztransmit/bztransmit09.log']]
    sources += list((base / 'bzlogs/bzreports_lastfilestransmitted').glob('*.xml'))
    reports = []
    indexed, transmitted = set(), set()
    flags = []
    for p in sources:
        data = bounded_file(p)
        _write(out / p.name, data)
        reports.append({'path': str(p.relative_to(base)), 'mtime': p.stat().st_mtime, 'size': len(data)})
        text = data.decode('utf-8', errors='strict')
        if p.name.endswith('_filelist.dat'):
            for line in text.splitlines():
                cols = line.split('\t')
                if len(cols) == 4 and cols[0] == 'f' and cols[3] in expected:
                    indexed.add(cols[3])
        if p.name == '09.log':
            for line in text.splitlines():
                for path in expected:
                    if line.endswith(' - ' + path):
                        transmitted.add(path)
        if p.name == 'bzhost_testimony_x.xml':
            flags = [{k: e.get(k) for k in ('filepath', 'selected_for_backup', 'type')}
                     for e in ET.fromstring(data).iter('mountpoint')]
    result = {'captured_utc': stamp, 'reports': reports, 'selection_flags': flags,
              'indexed': sorted(indexed), 'transmitted': sorted(transmitted),
              'unexplained_index_omissions': sorted(expected - indexed),
              'pending_transmission': sorted(expected - transmitted),
              'acceptance': 'manual timestamp/completion review required; restore pending'}
    _write(out / 'observations.json', json.dumps(result, indent=2).encode())
    verify_bundle(out)
    print(json.dumps({'evidence': str(out), 'indexed_count': len(indexed),
                      'transmitted_count': len(transmitted), 'selection_flags': flags}))


if __name__ == '__main__':
    main()
