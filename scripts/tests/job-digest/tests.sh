#!/bin/sh
# Tests for general/job-digest-config.json — the external config mounted into
# the job-digest service ( see general/job-digest.yml: JOB_DIGEST_CONFIG).
#
# `make validate` only treats the file as a bind-mount path, so a syntax
# error or a dropped/renamed key passes CI and surfaces only as a runtime
# crash-loop or silent fallback to the image-baked config. These tests parse
# it with python3's sqlite3-independent stdlib json module and pin the
# required keys and their shape.
#
# Skipped (reported as such, never counted as pass) on hosts without
# python3 — the same skip shape scripts/tests/backup/tests.sh uses for its
# sqlite-dependent case.

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
CFG="$REPO/general/job-digest-config.json"
pass=0; fail=0; skipped=0
ok()  { pass=$((pass+1)); echo "  ok  $*"; }
bad() { fail=$((fail+1)); echo "  FAIL $*"; }
skip() { skipped=$((skipped+1)); echo "  ok  $* (SKIPPED: no python3)"; }

echo "== job-digest external config"

if ! command -v python3 >/dev/null 2>&1; then
  skip "config parses as JSON, provider/model keys present"
  skip "one config entry per override slot"
  exit_status=0
else
  # 1. The file parses as JSON.
  if python3 -m json.tool "$CFG" >/dev/null 2>&1; then
    ok "config parses as JSON"
    parse_ok=1
  else
    bad "config does not parse as JSON"
    parse_ok=0
  fi

  # 2. Required keys exist and carry provider+model strings.
  result=$(python3 - "$CFG" <<'EOF'
import json, sys
cfg = json.load(open(sys.argv[1]))
missing = [k for k in ("classification", "hn_extraction", "resume_generation") if k not in cfg]
if missing:
    print("MISSING " + ",".join(missing)); raise SystemExit(0)
shape_bad = []
for k, v in cfg.items():
    if not isinstance(v, dict) or not isinstance(v.get("provider"), str) or not isinstance(v.get("model"), str):
        shape_bad.append(k)
if shape_bad:
    print("SHAPE " + ",".join(shape_bad)); raise SystemExit(0)
print("OK")
EOF
)
  case "$result" in
    OK) ok "provider/model keys present in every slot" ;;
    MISSING*) bad "config missing override slots: ${result#MISSING }" ;;
    SHAPE*) bad "config slots without string provider+model: ${result#SHAPE }" ;;
    *) bad "unexpected checker result: $result" ;;
  esac

  exit_status=$([ "$parse_ok" = 1 ] && [ "${result:-}" = OK ] 2>/dev/null && echo 0 || echo 1)
fi

echo "  total: $pass passed, $fail failed$([ "$skipped" -gt 0 ] && printf ', %d skipped' "$skipped")"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
