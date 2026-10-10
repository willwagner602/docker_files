"""Opt-in fixture preparation and verification; never starts or attaches a container."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import stat
import subprocess
import sys
import time
import uuid

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from collect import _safe_output, verify_bundle, bounded_file  # noqa: E402
from runtime import fixture_override  # noqa: E402

UID = 1000
MAX_LOG = 2 * 1024 * 1024

def fail(msg):
    raise RuntimeError(msg)

def fs_info(path):
    p = subprocess.run(["findmnt", "-T", str(path), "-n", "-o", "FSTYPE,OPTIONS"], text=True, capture_output=True, check=False)
    if p.returncode or not p.stdout.strip(): fail("cannot determine filesystem")
    bits = p.stdout.strip().split(None, 1)
    return {"fstype": bits[0], "subvol": bits[1] if len(bits) > 1 else ""}

def dev_info(path):
    s = os.stat(path)
    return {"st_dev": s.st_dev, "major": os.major(s.st_dev), "minor": os.minor(s.st_dev)}

def digest(path):
    h = hashlib.sha256(); size = 0
    with path.open("rb") as f:
        while True:
            b = f.read(1024 * 1024)
            if not b: break
            h.update(b); size += len(b)
    return {"sha256": h.hexdigest(), "size": size}

def regular_inventory(root):
    out = {}
    for p in sorted(root.rglob("*")):
        rel = p.relative_to(root).as_posix()
        if rel == ".bzvol" or rel.startswith(".bzvol/"): continue
        s = p.lstat()
        if stat.S_ISREG(s.st_mode): out[rel] = digest(p)
        elif not stat.S_ISDIR(s.st_mode): fail("fixture contains non-directory/non-file")
    return out

def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    path.chmod(0o600)

def prepare(parent):
    token = uuid.uuid4().hex
    source = Path("/bigdisk") / ("backblaze-fixture-" + token)
    marker = Path("/home/wbw") / ("backblaze-fixture-markers-" + token)
    if source.exists() or marker.exists(): fail("unique fixture path collision")
    source_fs = fs_info(Path("/bigdisk"))
    marker_fs = fs_info(Path("/home/wbw"))
    if source_fs["fstype"] != "btrfs": fail("/bigdisk is not btrfs")
    if marker_fs["fstype"] != "ext4": fail("marker parent is not ext4")
    source.mkdir(mode=0o700); marker.mkdir(mode=0o700)
    try:
        root_name = "fixture-root-" + secrets.token_hex(8) + ".txt"
        nested_name = "fixture-nested-" + secrets.token_hex(8) + ".txt"
        nested = source / "nested"; nested.mkdir(mode=0o700)
        (source / root_name).write_text("fixture-" + secrets.token_hex(24) + "\n")
        (nested / nested_name).write_text("nested-" + secrets.token_hex(24) + "\n")
        (source / ".bzvol").mkdir(mode=0o700)
        for p in (source, nested, source / ".bzvol"):
            os.chown(p, UID, os.getgid()); p.chmod(0o700)
        for p in (source / root_name, nested / nested_name):
            os.chown(p, UID, os.getgid()); p.chmod(0o600)
        os.chown(marker, UID, os.getgid()); marker.chmod(0o700)
        manifest = {"version": 1, "source": str(source), "marker": str(marker),
                    "source_fs": source_fs, "marker_fs": marker_fs,
                    "source_dev": dev_info(source), "marker_dev": dev_info(marker),
                    "root_name": root_name, "nested_name": "nested/" + nested_name,
                    "files": regular_inventory(source)}
        out = _safe_output(parent)
        write_json(out / "fixture-manifest.json", manifest)
        write_json(out / "compose-fixture-override.json", fixture_override(source, marker))
        write_json(out / "summary.json", {"kind": "fixture", "acceptance": "blocked",
                                           "created_utc": time.time()})
        verify_bundle(out)
        print(json.dumps({"bundle": str(out), "source": str(source), "marker": str(marker)}))
        return 0
    except Exception:
        shutil.rmtree(source, ignore_errors=True); shutil.rmtree(marker, ignore_errors=True)
        raise

def run_exec(args, log):
    p = subprocess.run(args, text=True, capture_output=True, check=False, timeout=60)
    raw = (p.stdout + p.stderr).encode()
    if len(raw) > MAX_LOG: fail("raw log exceeds limit")
    log.write_bytes(raw); log.chmod(0o600)
    if p.returncode: fail("probe failed: " + " ".join(args[:3]))
    return p.stdout

def verify(bundle):
    bundle = Path(bundle).resolve(strict=True); verify_bundle(bundle)
    m = json.loads((bundle / "fixture-manifest.json").read_text())
    source, marker = Path(m["source"]), Path(m["marker"])
    if regular_inventory(source) != m["files"]: fail("source manifest changed before probes")
    before = regular_inventory(source)
    mountinfo = bounded_file("/proc/self/mountinfo")
    (bundle / "mountinfo.txt").write_bytes(mountinfo); (bundle / "mountinfo.txt").chmod(0o600)
    insp = run_exec(["docker", "inspect", "Backblaze64"], bundle / "docker-inspect.log")
    data = json.loads(insp)
    if len(data) != 1: fail("unexpected inspect result")
    c = data[0]
    if c.get("Name") != "/Backblaze64": fail("wrong container")
    if c.get("HostConfig", {}).get("Privileged") or c.get("HostConfig", {}).get("CapAdd") or c.get("HostConfig", {}).get("SecurityOpt"):
        fail("container privilege/security override present")
    mounts = c.get("Mounts", [])
    expected = {(str(source), "/drive_f", False), (str(marker), "/drive_f/.bzvol", True)}
    actual = {(x.get("Source"), x.get("Destination"), bool(x.get("RW"))) for x in mounts if x.get("Destination", "").startswith("/drive_f")}
    if actual != expected: fail("exact fixture binds not present")
    container_mountinfo = run_exec(['docker', 'exec', '--user', '1000:1000',
        'Backblaze64', 'python3', '-c',
        "print(open('/proc/self/mountinfo').read(), end='')"], bundle / 'container-mountinfo.txt')
    lines = container_mountinfo.splitlines()
    def mount_entry(point, fstype, readonly, dev):
        found = [x for x in lines if len(x.split(" - ", 1)) == 2 and x.split(" - ", 1)[0].split()[4] == point]
        if len(found) != 1: fail("mountinfo mountpoint count: " + point)
        left, right = found[0].split(" - ", 1); fields, superopts = right.split(), left.split()
        # Btrfs st_dev is a subvolume device and can differ from mountinfo's device.
        host_path = source if point == '/drive_f' else marker
        host_mount_dev = subprocess.check_output(['findmnt', '-T', str(host_path), '-n', '-o', 'MAJ:MIN'], text=True).strip()
        if fields[0] != fstype or ("ro" in superopts[5].split(",")) != readonly or superopts[2] != host_mount_dev:
            fail("mountinfo mismatch: " + point)
        actual_dev = run_exec(['docker', 'exec', '--user', '1000:1000', 'Backblaze64',
            'python3', '-c', 'import os; print(os.stat(' + repr(point) + ').st_dev)'],
            bundle / ('source-device.txt' if point == '/drive_f' else 'marker-device.txt'))
        if int(actual_dev.strip()) != dev['st_dev']:
            fail('stat device mismatch: ' + point)
    mount_entry("/drive_f", "btrfs", True, m["source_dev"])
    mount_entry("/drive_f/.bzvol", "ext4", False, m["marker_dev"])
    script = "import errno, pathlib, hashlib, uuid\nfiles=" + repr(m['files']) + "\n" + """
p=pathlib.Path('/drive_f'); m=p/'.bzvol'
for relative, info in files.items():
  q=p/relative
  data=q.read_bytes()
  assert len(data)==info['size'] and hashlib.sha256(data).hexdigest()==info['sha256']
  for op in (lambda: q.write_bytes(b'x'), lambda: q.rename(q.with_name(q.name+'.x')), lambda: q.unlink()):
    try: op(); raise SystemExit(3)
    except OSError as e: assert e.errno==errno.EROFS
try: (p/('probe-'+uuid.uuid4().hex)).write_bytes(b'x'); raise SystemExit(3)
except OSError as e: assert e.errno==errno.EROFS
x=m/('probe-'+uuid.uuid4().hex); y=x.with_suffix('.renamed')
x.write_text('ok'); x.rename(y); y.unlink()
"""
    env = {"HOME":"/config", "WINEPREFIX":"/config/wine"}
    run_exec(["docker", "exec", "--user", "1000:1000", "-e", "HOME=/config", "-e", "WINEPREFIX=/config/wine", "Backblaze64", "python3", "-c", script], bundle / "probes.log")
    wine_root = run_exec(["docker", "exec", "--user", "1000:1000", "-e", "HOME=/config", "-e", "WINEPREFIX=/config/wine", "Backblaze64", "wine", "cmd", "/c", "dir", "F:\\"], bundle / "wine-dir-root.log")
    wine_nested = run_exec(["docker", "exec", "--user", "1000:1000", "-e", "HOME=/config", "-e", "WINEPREFIX=/config/wine", "Backblaze64", "wine", "cmd", "/c", "dir", "F:\\nested"], bundle / "wine-dir-nested.log")
    if m["root_name"] not in wine_root or Path(m["nested_name"]).name not in wine_nested: fail("wine enumeration missing known names")
    if regular_inventory(source) != before: fail("host fixture changed")
    write_json(bundle / "verify-summary.json", {"acceptance":"blocked", "verified":True})
    verify_bundle(bundle); print(json.dumps({"bundle":str(bundle), "acceptance":"blocked"})); return 0

def main():
    ap = argparse.ArgumentParser(); sub = ap.add_subparsers(dest="command", required=True)
    p = sub.add_parser("prepare"); p.add_argument("--evidence-parent", type=Path, required=True)
    v = sub.add_parser("verify"); v.add_argument("bundle", type=Path)
    a = ap.parse_args(); os.umask(0o077)
    return prepare(a.evidence_parent) if a.command == "prepare" else verify(a.bundle)

if __name__ == "__main__":
    try: raise SystemExit(main())
    except Exception as e: print("fixture error: " + str(e), file=sys.stderr); raise SystemExit(1)
