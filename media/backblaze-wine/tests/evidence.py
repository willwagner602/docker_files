"""Fail-closed evidence boundary; no installed Backblaze format is assumed."""
from dataclasses import dataclass, field
from pathlib import Path
import os

BLOCKED = "installed report formats and completed scan correlation are not validated"

@dataclass
class NormalizedEvidence:
    run_start: object
    run_end: object
    expected_manifest: set[str]
    transmitted: set[str]
    rules: dict[str, str] = field(default_factory=dict)
    unreadable: set[str] = field(default_factory=set)
    pending: set[str] = field(default_factory=set)
    unexplained: set[str] = field(default_factory=set)
    def reconcile(self):
        if self.run_start is None or self.run_end is None or self.run_end < self.run_start:
            raise ValueError("run start/end timestamps are required")
        # Synthetic set reconciliation only; this is not report provenance validation.
        groups = [self.transmitted, set(self.rules), self.unreadable, self.pending]
        if any(not self.expected_manifest.issuperset(group) for group in groups):
            raise ValueError("status paths absent from expected manifest")
        if any(not isinstance(rule, str) or not rule.strip() for rule in self.rules.values()):
            raise ValueError("exclusions require an explicit rule")
        for i, group in enumerate(groups):
            if any(group & other for other in groups[i + 1:]):
                raise ValueError("ambiguous overlapping status categories")
        excluded = set(self.rules)
        # Pending must be explicitly evidenced, never the fallback for omissions.
        self.unexplained = self.expected_manifest - self.transmitted - excluded - self.unreadable - self.pending
        return self

@dataclass
class Evidence:
    indexed: set[str] = field(default_factory=set)
    transmitted: set[str] = field(default_factory=set)
    excluded_with_rule: set[str] = field(default_factory=set)
    unreadable: set[str] = field(default_factory=set)
    pending: set[str] = field(default_factory=set)
    unexplained: set[str] = field(default_factory=set)
    errors: list[str] = field(default_factory=list)
    inventory: dict[str, list[str]] = field(default_factory=dict)
    blocked: bool = False

class EvidenceParser:
    def __init__(self, root, **_kwargs): self.root = Path(root)
    def inventory_only(self):
        out = {k: [] for k in ("regular", "dir", "symlink", "unreadable", "error", "mount")}
        out["subvolume"] = ["unavailable: no subvolume inventory provider"]
        try: root_dev = os.lstat(self.root).st_dev
        except OSError as e:
            out["error"].append(f".: {e.__class__.__name__}"); return out
        def onerror(e):
            try: rel = os.path.relpath(e.filename, self.root)
            except (TypeError, ValueError): rel = "."
            out["error"].append(f"{rel}: {e.__class__.__name__}")
        for d, dirs, files in os.walk(self.root, followlinks=False, onerror=onerror):
            for name, kind in [(n, "dir") for n in dirs] + [(n, "regular") for n in files]:
                p = Path(d) / name
                try:
                    s = os.lstat(p); rel = os.path.relpath(p, self.root)
                    if os.path.islink(p): out["symlink"].append(rel)
                    elif s.st_dev != root_dev: out["mount"].append(rel)
                    elif kind == "dir": out["dir"].append(rel)
                    else: out["regular"].append(rel)
                except PermissionError: out["unreadable"].append(os.path.relpath(p, self.root))
                except OSError as e: out["error"].append(f"{os.path.relpath(p, self.root)}: {e.__class__.__name__}")
        return out
    def parse(self):
        e = Evidence(blocked=True, errors=[BLOCKED])
        e.inventory = self.inventory_only()
        return e

def parse_evidence(root, **kwargs):
    return EvidenceParser(root, **kwargs).parse()
