#!/bin/sh
# Test the docker-ro allowlist wrapper (scripts/docker-ro-wrapper.sh).
#
# The wrapper is a security boundary: it is the `command=` target for the
# docker-ro SSH key, and its whole job is to refuse everything that is not a
# read-only inspection. These tests assert that boundary in both directions:
# allowed subcommands reach docker, and every write/escape verb is refused.
#
# docker is stubbed, so nothing touches a real daemon and no host is needed.
#
#   sh scripts/tests/docker-ro/wrapper.sh

set -u

repo_dir=$(cd "$(dirname "$0")/../../.." && pwd)
wrapper_src=$repo_dir/scripts/docker-ro-wrapper.sh

[ -f "$wrapper_src" ] || { echo "missing $wrapper_src" >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/docker-ro-test.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

mkdir -p "$work/bin"
cat > "$work/bin/docker" <<'STUB'
#!/bin/sh
echo "STUB-DOCKER-ARGS: $*"
# Emit both a diagnostic-shaped and a secret-shaped line so the caller can
# assert the wrapper's log filter keeps the former and drops the latter.
case "$*" in
  logs*)
    echo "stub: ERROR: diagnostic line"
    echo "stub: PLEX_CLAIM_TOKEN=leaked-value"
    ;;
esac
STUB
chmod +x "$work/bin/docker"

# Point the wrapper at the stub. The wrapper resolves docker via resolve_docker(),
# which probes fixed absolute paths before falling back to PATH. Rewrite the
# probe list so the stub directory is the ONLY candidate, and drop the PATH
# fallback, so a real daemon can never be reached by this suite.
sed -e "s#for p in /usr/bin/docker /usr/local/bin/docker /snap/bin/docker /usr/sbin/docker; do#for p in $work/bin/docker; do#" \
    -e 's#^  found=\$(command -v docker 2>/dev/null) || return 1#  return 1#' \
    "$wrapper_src" > "$work/wrapper.sh"
chmod +x "$work/wrapper.sh"

# Guard: if the rewrite did not take effect, the suite would silently test the
# real daemon (which is exactly the failure this comment exists to prevent).
if ! grep -q "$work/bin/docker" "$work/wrapper.sh"; then
  echo "FATAL: could not point wrapper at the stub; resolve_docker() shape changed" >&2
  exit 1
fi

pass=0
fail=0

# run <expected-substring> <label> <args...>
# Asserts the wrapper's output contains the substring (either a stub echo, a
# rejection message, or usage text).
run() {
  expect=$1
  label=$2
  shift 2
  out=$("$work/wrapper.sh" "$@" 2>&1)
  if printf '%s' "$out" | grep -qF "$expect"; then
    printf '  ok   %-44s\n' "$label"
    pass=$((pass + 1))
  else
    printf '  FAIL %-44s got: %s\n' "$label" "$(printf '%s' "$out" | head -n1)"
    fail=$((fail + 1))
  fi
}

# refute <forbidden-substring> <label> <args...>
# Asserts the wrapper did NOT reach docker: used for the negatives, so a
# rejection that still ran docker would be caught.
refute() {
  forbidden=$1
  label=$2
  shift 2
  out=$("$work/wrapper.sh" "$@" 2>&1) || true
  if printf '%s' "$out" | grep -qF "$forbidden"; then
    printf '  FAIL %-44s reached docker: %s\n' "$label" "$(printf '%s' "$out" | head -n1)"
    fail=$((fail + 1))
  else
    printf '  ok   %-44s\n' "$label"
    pass=$((pass + 1))
  fi
}

echo "== allowed subcommands reach docker =="
run "ps -a --no-trunc"            "ps"                 ps
run "image ls --digests --no-trunc" "images"           images
run "STUB-DOCKER-ARGS: version"   "version"            version
run "STUB-DOCKER-ARGS: info"      "info"               info
run "inspect abcdef123456"        "inspect <hex>"      inspect abcdef123456
run "State.Health"                "health <hex>"       health abcdef123456
run "json .Config"                "config <hex>"       config abcdef123456
run "USAGE"                       "help"               help

echo "== logs is filtered, logs-raw is gated =="
# `logs` pipes the stub's output through the diagnostic whitelist, so the stub
# echo alone would be filtered away. The stub therefore also emits an
# error-shaped line, and we assert that survives while a secret-shaped line
# (also emitted by the stub) does not. See the stub definition above.
run "stub: ERROR: diagnostic line" "logs keeps diagnostic" logs abcdef123456
refute "stub: PLEX_CLAIM_TOKEN" "logs drops secret line" logs abcdef123456
refute "STUB-DOCKER-ARGS" "logs-raw refused by default" logs-raw abcdef123456

echo "== image references accepted =="
run "inspect ghcr.io/immich-app/immich-server:v3.1.0" "inspect image:tag" \
  inspect ghcr.io/immich-app/immich-server:v3.1.0
run "inspect linuxserver/plex"    "inspect repo/path"  inspect linuxserver/plex

echo "== write and escape verbs refused =="
for verb in run create start stop restart kill rm rmi exec cp save export \
            load import build push pull login logout secret swarm node \
            system plugin context trust; do
  refute "STUB-DOCKER-ARGS" "$verb refused" "$verb"
done

echo "== argument injection refused =="
refute "STUB-DOCKER-ARGS" "ps with --format"     ps --format '{{.Names}}'
refute "STUB-DOCKER-ARGS" "inspect with --format" inspect --format '{{.Config}}' abc
refute "STUB-DOCKER-ARGS" "id plus privileged"   inspect abcdef123456 --privileged
refute "STUB-DOCKER-ARGS" "leading dash"         inspect -v
refute "STUB-DOCKER-ARGS" "shell metachar"       inspect 'abc;id'
refute "STUB-DOCKER-ARGS" "traversal"            inspect '../../etc/shadow'
refute "STUB-DOCKER-ARGS" "dollar expansion"     inspect '$(id)'
refute "STUB-DOCKER-ARGS" "backtick expansion"   inspect '`id`'
refute "STUB-DOCKER-ARGS" "uppercase hex"        inspect ABCDEF123456
refute "STUB-DOCKER-ARGS" "mid-arg injection"    logs abc def

echo "== missing id refused =="
refute "STUB-DOCKER-ARGS" "inspect no id"        inspect
refute "STUB-DOCKER-ARGS" "logs no id"           logs
refute "STUB-DOCKER-ARGS" "health no id"         health

printf '\ndocker-ro wrapper: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
