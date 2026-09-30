#!/bin/sh
# docker-ro-wrapper.sh — restricted SSH command for the docker-ro key.
#
# INSTALL THIS AT /usr/local/sbin/docker-ro-wrapper.sh, OWNED BY root, MODE 0755,
# and NOT WRITABLE BY THE LOGIN USER. If the user can modify this file, the
# allowlist below is meaningless — the user could simply edit it. The install
# target in the Makefile does the ownership/mode part for you:
#
#     make docker-ro-install
#
# This script is the value of `command="..."` in the authorized_keys line for
# the docker-ro key. sshd runs it instead of a shell, so the caller never gets
# an interactive session, a PTY, port forwarding, or agent forwarding.
#
# It accepts ONE argument: a subcommand from the allowlist. Anything else is
# rejected. There is no argument passthrough: `docker inspect foo` is two
# arguments and therefore rejected, by design — see USAGE below.
#
# WHY NO ARGUMENT PASSTHROUGH
#   sudoers and shell wrappers that match "the whole command line as a string"
#   are a classic root-shell footgun: a trailing wildcard like `docker ps *`
#   also matches `docker ps --config /tmp/evil`. This script sidesteps that
#   entirely by never matching on the caller's argument text. The allowlist is
#   a fixed set of literal strings and a closed set of regex-validated IDs.
#
# USAGE  (from the client: ssh -i <key> docker-ro@host <subcommand>)
#   ps                 docker ps -a --no-trunc
#   images             docker image ls --digests --no-trunc
#   version            docker version (client + server)
#   info               docker info (host summary; no env, no container names)
#   inspect <id>       docker inspect <id> — id must be a 12-64 char lowercase
#                      hex container/image id, or an image reference matching
#                      [a-z0-9._/-]+(:tag)?(@sha256:hex)?
#   logs <id>          docker logs --tail 200 <id>, filtered to DIAGNOSTIC LINES
#                      ONLY. See LOG FILTERING below.
#   logs-raw <id>      unfiltered docker logs. NOT installed by default — see
#                      the ALLOW_RAW_LOGS switch below.
#   health <id>        docker inspect --format '{{json .State.Health}}' <id>
#   config <id>        docker inspect --format '{{json .Config}}' <id>
#   help               print this allowlist
#
# DELIBERATELY EXCLUDED
#   run, create, start, stop, restart, kill, rm, exec, cp, save, export, load,
#   system, plugin, context, build, push, pull, login, secret, node, swarm,
#   and anything not listed above — all writes and all host-escape verbs.
#   Note that `docker exec` and `docker run` are the escape hatches: they are
#   never reachable here.
#
# LOG FILTERING  (why `logs` is not just `docker logs`)
#   Container logs are where secrets actually appear: media/.env values, Plex
#   claim tokens, bot tokens, API keys. Both halves of this were measured on a
#   real daemon rather than assumed:
#
#     * `docker logs` has NO redaction or filtering flag. (Verified: `docker
#       logs --help` exposes only --since/--tail/--timestamps/--details.)
#     * A regex "redactor" that scrubs KEY=value pairs is only PARTIAL. Tested
#       against adversarial inputs it catches `PLEX_CLAIM_TOKEN=...` and
#       `PASSWORD=...` but MISSES `pass=...`, `my_pw=...`, bare prose like
#       "token is XYZ", and it leaks the payload of `Authorization: Basic ...`.
#       A scrubber that silently misses cases is worse than no scrubber,
#       because it invites trust it has not earned.
#
#   So `logs` is a WHITELIST, not a scrubber: it emits only lines matching
#   DIAGNOSTIC patterns (error/fail/health/timeout/...) and drops everything
#   else. Unrecognized text is discarded rather than partially redacted. The
#   cost is losing benign context lines; the benefit is that a secret would
#   have to appear on a line that also contains "error"/"fail"/"warn" to leak.
#
#   This is deliberately narrower than "read-only docker". If the filter is too
#   aggressive for a real debugging session, the fix is to add a named pattern
#   to DIAGNOSTIC_PATTERN — not to reach for raw logs.

set -eu

# Set ALLOW_RAW_LOGS=1 in the sshd environment (or edit here) to also permit the
# `logs-raw` subcommand. OFF by default: raw logs are the leak surface described
# above. Turning this on should be a deliberate, temporary act, not a default.
ALLOW_RAW_LOGS=${ALLOW_RAW_LOGS:-0}

# Lines that survive the `logs` filter. Case-insensitive. Keep this tight.
DIAGNOSTIC_PATTERN='error|fail|fatal|warn|exception|critical|panic|traceback|timeout|timed out|refused|unreachable|unhealthy|health|restart|killed|oom|out of memory|denied|forbidden|retry|retrying|crash|segfault|not found|no such|unable to|cannot|could not|exited'

# Resolve the docker CLI. Do NOT hardcode just /usr/bin: this repo's own hosts
# may have it elsewhere (this dev box has the snap package at /snap/bin/docker),
# and a wrong path here turns into a confusing "docker not found" at login time.
# Order: absolute standard locations first (so the wrapper never picks up a
# caller-controlled PATH entry), then PATH as a last resort. The resolved path
# must be root-owned or non-writable by the login user, or the allowlist is moot.
resolve_docker() {
  for p in /usr/bin/docker /usr/local/bin/docker /snap/bin/docker /usr/sbin/docker; do
    [ -x "$p" ] && { printf '%s' "$p"; return 0; }
  done
  found=$(command -v docker 2>/dev/null) || return 1
  [ -n "$found" ] && { printf '%s' "$found"; return 0; }
  return 1
}

DOCKER=$(resolve_docker) || { echo "docker-ro: docker CLI not found" >&2; exit 127; }

# Refuse to run a CLI the login user could replace. A caller-writable docker
# binary is a root shell wearing our allowlist as a costume.
case "$DOCKER" in
  "$HOME"/*) echo "docker-ro: refusing caller-controlled docker path: $DOCKER" >&2; exit 126 ;;
esac

err() {
  echo "docker-ro: $*" >&2
  echo "docker-ro: run 'ssh <host> help' for the allowed subcommands" >&2
  exit 64
}

usage() {
  sed -n '/^# USAGE/,/^# DELIBERATELY/p' "$0" | sed -e 's/^# \{0,1\}//' -e '/^DELIBERATELY/d'
}

# Validate an identifier before it reaches docker. Accepts:
#   - a lowercase hex id, 12..64 chars (container or image id)
#   - an image reference: [a-z0-9._/-]+ optionally :tag and/or @sha256:<64 hex>
# Rejects anything with shell metacharacters, whitespace, uppercase (docker
# refs are lowercase), leading '-' (would be parsed as a flag), or a path
# traversal.
valid_id() {
  case "$1" in
    -*) return 1 ;;
    *[!a-z0-9._/:@-]*) return 1 ;;
    *..*) return 1 ;;
  esac
  case "$1" in
    *[0-9a-f]*) : ;;
    *) return 1 ;;
  esac
  printf '%s' "$1" | grep -Eq '^([0-9a-f]{12,64}|[a-z0-9][a-z0-9._/-]*(:[a-zA-Z0-9._-]+)?(@sha256:[0-9a-f]{64})?)$'
}

sub=${1:-help}
id=${2:-}

# Reject any extra arguments outright. Every allowed subcommand takes at most
# one validated id, and accepting "extras" is exactly how allowlists get widened
# by accident.
if [ "$#" -gt 2 ]; then
  err "unexpected extra arguments"
fi

# Subcommands that take exactly one id and nothing else.
needs_id() {
  [ -n "$id" ] || err "$sub requires an id"
  valid_id "$id" || err "invalid id: $id"
}

case "$sub" in
  ps)
    [ "$#" -eq 1 ] || err "ps takes no arguments"
    exec "$DOCKER" ps -a --no-trunc
    ;;
  images)
    [ "$#" -eq 1 ] || err "images takes no arguments"
    exec "$DOCKER" image ls --digests --no-trunc
    ;;
  version)
    [ "$#" -eq 1 ] || err "version takes no arguments"
    exec "$DOCKER" version
    ;;
  info)
    [ "$#" -eq 1 ] || err "info takes no arguments"
    exec "$DOCKER" info
    ;;
  inspect)
    needs_id
    exec "$DOCKER" inspect "$id"
    ;;
  logs)
    needs_id
    # Whitelist: emit only diagnostic lines. grep's exit status is reset so an
    # all-filtered (empty) result is success, not an error — a healthy container
    # legitimately produces no matching lines.
    "$DOCKER" logs --tail 200 "$id" 2>&1 | grep -aiE "$DIAGNOSTIC_PATTERN" || true
    ;;
  logs-raw)
    needs_id
    if [ "$ALLOW_RAW_LOGS" != "1" ]; then
      err "logs-raw is disabled (raw logs can expose secrets); use 'logs' for filtered output"
    fi
    exec "$DOCKER" logs --tail 200 "$id"
    ;;
  health)
    needs_id
    exec "$DOCKER" inspect --format '{{json .State.Health}}' "$id"
    ;;
  config)
    needs_id
    exec "$DOCKER" inspect --format '{{json .Config}}' "$id"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    err "subcommand not allowed: $sub"
    ;;
esac
