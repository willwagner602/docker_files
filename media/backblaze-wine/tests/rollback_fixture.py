"""Remove only the checkpoint-absent F mapping while client is stopped.

Container recreation is separate. Preserve all marker/source/config data.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import xml.etree.ElementTree as ET
from collect import _write, verify_bundle


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--checkpoint', required=True, type=Path)
    ap.add_argument('--fixture-bundle', required=True, type=Path)
    a = ap.parse_args()
    os.umask(0o077)
    verify_bundle(a.checkpoint); verify_bundle(a.fixture_bundle)
    state = json.loads(subprocess.check_output(['docker', 'inspect', 'Backblaze64']))[0]
    assert state['State']['Status'] == 'exited' and state['State']['Running'] is False
    config = Path('/bigdisk/backblaze-personal/config')
    info = config / 'wine/drive_c/ProgramData/Backblaze/bzdata/bzinfo.xml'
    data = info.read_bytes()
    volumes = ET.fromstring(data).find('hard_drives_to_backup')
    assert volumes is not None
    paths = [v.get('mountPointPath') for v in volumes]
    assert set(paths) == {'C:\\', 'D:\\'}, 'unexpected active drive selections'
    manifest = json.loads((a.checkpoint / 'manifest.json').read_text())
    assert not any(x['root'] == 'config' and x['path'] == 'wine/dosdevices/f:' for x in manifest['sources'])
    marker = Path('/home/wbw/backblaze-overlay-test/drive-root/.bzvol/bzvol_id.xml')
    with tarfile.open(a.checkpoint / 'checkpoint.tar') as archive:
        assert archive.extractfile('marker/bzvol_id.xml').read() == marker.read_bytes(), 'D identity changed'
    mapping = config / 'wine/dosdevices/f:'
    assert mapping.is_symlink() and os.readlink(mapping) == '/drive_f/'
    _write(a.fixture_bundle / 'deselected-bzinfo.xml', data)
    _write(a.fixture_bundle / 'rollback-before.json', json.dumps({
        'selected_drives': paths, 'removed_mapping': '/drive_f/',
        'd_marker_sha256': hashlib.sha256(marker.read_bytes()).hexdigest(),
        'checkpoint': str(a.checkpoint)}).encode())
    mapping.unlink()
    verify_bundle(a.fixture_bundle)
    print('F mapping removed; D marker unchanged; recreate original compose next.')


if __name__ == '__main__':
    main()
