"""Fail-closed validation of a retained Backblaze fixture evidence bundle."""
from __future__ import annotations
import argparse, json, os, re, sys
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from pathlib import Path
import xml.etree.ElementTree as ET

F_RE = re.compile(r"^f\t([0-9a-f]{16})\t([0-9]+)\t(.+)$")
LOG_RE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\s+([^\s]+)\s+-\s+(.*)$")
TS_RE = re.compile(r"^\d{14}$")
PID_RE = re.compile(r"(?:processid|processId|pid)=(\d+)", re.I)
PARENT_RE = re.compile(r"parent(?:pid|processid)=(\d+)", re.I)

def _dt(s):
    try: return datetime.strptime(s, "%Y%m%d%H%M%S").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError): return None

def _iso(s):
    try:
        if isinstance(s, (int, float)): return datetime.fromtimestamp(s, timezone.utc)
        d = datetime.fromisoformat(str(s).replace("Z", "+00:00"))
        return d.astimezone(timezone.utc)
    except (TypeError, ValueError): return None

def _norm(p):
    p = str(p).replace("/", "\\")
    if p.startswith("\\\\?\\"): p = p[4:]
    return p

def _path(p):
    p = _norm(p)
    return p if re.match(r"^[A-Za-z]:\\[^\\].*", p) else None

@dataclass
class FixtureEvidence:
    indexed: set[str]; transmitted: set[str]; pending: set[str]; unexplained: set[str]
    errors: list[str]; blocked: bool
    scan_timestamp: str | None = None; transmit_timestamp: str | None = None
    selected_volumes: dict[str, bool] | None = None
    def restricted(self):
        d=asdict(self)
        for k in ("indexed","transmitted","pending","unexplained"): d[k]=sorted(d[k])
        return d

def _capture(root, requested, errors):
    if requested:
        p=Path(requested)
        if not p.is_absolute(): p=root/p
        if not p.is_dir(): errors.append("capture folder missing")
        return p
    found=sorted(p for p in root.iterdir() if p.is_dir() and p.name.startswith("upload-check-")) if root.is_dir() else []
    if len(found)!=1: errors.append("expected exactly one upload-check folder")
    return found[0] if len(found)==1 else root/"__missing_capture__"

def parse_bundle(root, *, expected=None, capture=None):
    root=Path(root); errors=[]; indexed=set(); transmitted=set(); selected={}
    if not root.is_dir(): return FixtureEvidence(set(),set(),set(),set(),["bundle root missing"],True)
    try: manifest=json.loads((root/"fixture-manifest.json").read_text())
    except Exception as e: manifest=None; errors.append(f"manifest: {e}")
    if not isinstance(manifest,dict) or not isinstance(manifest.get("files"),dict):
        errors.append("manifest files required"); manifest={}
    if not manifest.get("files"): errors.append("manifest files must not be empty")
    expected = {"F:\\"+str(k).replace("/","\\"): v.get("size") for k,v in manifest.get("files",{}).items() if isinstance(v,dict) and isinstance(v.get("size"),int)} if expected is None else expected
    if expected is None: expected={}
    summary=None
    try: summary=json.loads((root/"summary.json").read_text())
    except Exception as e: errors.append(f"summary: {e}")
    start=_iso(summary.get("created_utc")) if isinstance(summary,dict) else None
    if start is None: errors.append("summary created_utc malformed or missing")
    up=_capture(root,capture,errors)
    fls=list(up.glob("*_f____filelist.dat")); scan=None
    if len(fls)!=1: errors.append("expected exactly one upload filelist")
    if fls:
        lines=fls[0].read_text(errors="replace").splitlines()
        hdr=[x for x in lines if x.startswith("# GmtMillisThisListWasStarted:")]
        if len(hdr)!=1: errors.append("missing or ambiguous list-start header")
        else:
            m=re.search(r"GmtDateTime:\s*(\d{14})$",hdr[0]); scan=m.group(1) if m else None
            if not scan or not _dt(scan): errors.append("malformed list-start timestamp")
        for n,line in enumerate(lines,1):
            if line.startswith("f"):
                m=F_RE.match(line)
                if not m: errors.append(f"malformed f record line {n}"); continue
                p=_path(m.group(3))
                if not p: errors.append(f"wrong path prefix line {n}"); continue
                size=int(m.group(2))
                if p in indexed and expected.get(p)!=size: errors.append(f"duplicate conflicting path: {p}")
                indexed.add(p)
                if p in expected and expected[p]!=size: errors.append(f"wrong size: {p}")
    try:
        fs=ET.parse(up/"filestats.xml").getroot(); prog=fs.find("progress"); info=fs.find("info")
        if prog is None or prog.get("totally_final")!="true": errors.append("filestats not totally_final")
        if info is None or info.get("datetime")!=scan: errors.append("filestats datetime mismatch")
    except Exception as e: errors.append(f"filestats: {e}")
    tx_times=[]
    for x in up.glob("bzstat_pervol_*_latest_file.xml"):
        try:
            a=ET.parse(x).getroot().find("lastfile_transmitted").attrib
            if a.get("gmt_date_that_per_vol_filelist_was_generated")!=scan: continue
            p=_path(a.get("filename")); t=a.get("gmt_date")
            if p in expected:
                transmitted.add(p)
                if not _dt(t): errors.append("bad per-volume transmission timestamp")
                else: tx_times.append(t)
        except Exception as e: errors.append(f"per-volume XML: {e}")
    tx=min(tx_times) if tx_times else None
    day=up/"09.log"; day_times=[]
    if day.exists():
        for line in day.read_text(errors="replace").splitlines():
            m=re.match(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\s+-\s+.*?\s+-\s+(.+)$",line)
            if m and _path(m.group(2)) in expected:
                transmitted.add(_path(m.group(2))); parsed=_iso(m.group(1)+"+00:00")
                if parsed: day_times.append(parsed)
                else: errors.append("bad day log timestamp")
    events=[]; log=up/"bztransmit09.log"
    if log.exists():
        for line in log.read_text(errors="replace").splitlines():
            m=LOG_RE.match(line)
            if not m: continue
            stamp, prefix, text = m.groups()
            pm=PID_RE.search(text) or (re.fullmatch(r"\d+", prefix) and re.match(r"(\d+)", prefix))
            events.append((_iso(stamp+"+00:00"),pm.group(1) if pm else None,text))
    success=[e for e in events if "Leaving bztrans_thread_push - very successful" in e[2]]
    receipt=[e for e in events if "very successful fully received the file from main bztransmit" in e[2]]
    launch=[e for e in events if "About to async run bztransmit -threadpush" in e[2]]
    finish=[e for e in events if "TransmitFilesAccordingToTheTodoList - finished" in e[2]]
    # The evidence directory is copied after events; its name/mtime is capture time,
    # not run start. Use the fixture creation timestamp plus per-path event times.
    capture_start=start
    capture_end=max(day_times) if day_times else None
    if not capture_end: errors.append("missing path-keyed transmission timestamps")
    if capture_end and capture_start and capture_end < capture_start: errors.append("transmission precedes fixture creation")
    def in_window(e): return e[0] and (not capture_start or e[0] >= capture_start) and (not capture_end or e[0] <= capture_end)
    correlated=False
    for s in success:
        if not in_window(s): continue
        child=s[1]
        if not child: continue
        received=[r for r in receipt if r[1] == child and in_window(r)]
        if not received: continue
        thread_xml=re.search(r'instruction filename=([^,]+)', received[-1][2], re.I)
        if not thread_xml: continue
        xml_name=thread_xml.group(1).strip().strip('"')
        parent_match=re.search(r'_instru_(\d+)_\d+_bzt\.xml', xml_name, re.I)
        parent_pid=parent_match.group(1) if parent_match else None
        launched=any(l[1] == parent_pid and l[0] <= s[0] and (s[0]-l[0]).total_seconds() <= 60 for l in launch)
        if not parent_pid or not launched: continue
        for f in finish:
            if not f[0] or not parent_pid or f[1] != parent_pid: continue
            if f[0] >= s[0] and (f[0]-s[0]).total_seconds() <= 60:
                correlated=True
                break
    if not correlated: errors.append("no correlated child success and parent finish")
    # Do not infer the run boundary from whichever finish event happens to be latest.
    end=datetime.fromtimestamp(up.stat().st_mtime, timezone.utc) if up.exists() else None
    if start and end and end<start: errors.append("capture end precedes run start")
    if tx and scan and (not _dt(scan) or _dt(tx)<_dt(scan)): errors.append("transmission precedes scan")
    tx_dt = _dt(tx) if tx else None
    if tx_dt and success and end and not any(e[0] and e[0] <= tx_dt <= end for e in success if e[0]): errors.append("per-volume timestamp outside success/finish interval")
    try:
        for e in ET.parse(up/"bzhost_testimony_x.xml").iter():
            fp=e.get("filepath"); flag=e.get("selected_for_backup")
            if fp and flag is not None and fp.endswith("\\"):
                p=_norm(fp)
                if not re.match(r"^[A-Za-z]:\\$",p): errors.append("wrong selection path prefix"); continue
                if flag not in ("true","false"): errors.append("selection flag must be true/false"); continue
                b=flag=="true"
                if p in selected and selected[p]!=b: errors.append("ambiguous selection flag")
                selected[p]=b
        for d,v in {"C:\\":True,"D:\\":True,"F:\\":True,"Z:\\":False}.items():
            if selected.get(d) is not v: errors.append("selection flags missing or wrong")
    except Exception as e: errors.append(f"selection XML: {e}")
    missing=set(expected)-indexed
    if missing: errors.append("expected paths not indexed: "+", ".join(sorted(missing)))
    if set(expected)-transmitted: errors.append("expected paths not transmitted")
    return FixtureEvidence(indexed,transmitted,set(expected)-indexed,set(expected)-indexed-transmitted,errors,bool(errors),scan,tx,selected)

def main(argv=None):
    p=argparse.ArgumentParser(); p.add_argument("bundle"); p.add_argument("--capture"); p.add_argument("--emit-restricted",action="store_true"); p.add_argument("--output")
    a=p.parse_args(argv)
    if not a.emit_restricted: p.error("refusing output without --emit-restricted")
    e=parse_bundle(a.bundle,capture=a.capture); out=json.dumps(e.restricted(),sort_keys=True)+"\n"
    if a.output:
        fd=os.open(a.output,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(fd,"w") as f: f.write(out)
    else: sys.stdout.write(out)
    return 1 if e.blocked else 0
if __name__ == "__main__": raise SystemExit(main())
