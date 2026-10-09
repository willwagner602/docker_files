#!/bin/sh
# Launch the Komodo MCP server in stdio mode, for use as a Polytoken MCP server.
#
# Komodo has no first-party MCP server. This runs MP-Tool's third-party server
# (https://github.com/MP-Tool/komodo-mcp-server) pinned by image digest, with
# the write/exec/delete tool categories removed so the tool surface the model
# sees is read-only. See README.md ("Komodo via MCP") for the rationale.
#
# The credential never reaches the model or the command line: this script reads
# it from the environment (or a 600 credential file), exports it, and hands
# docker only the *variable name* (`-e KOMODO_API_KEY`), so the value travels
# in the process environment rather than in argv, where `ps` would show it.
#
# Usage:
#   scripts/komodo-mcp.sh
#
# Credentials, in priority order:
#   1. Environment: KOMODO_API_KEY / KOMODO_API_SECRET, or the equivalent
#      KOMODO_SERVICE_KEY / KOMODO_SERVICE_SECRET (both accepted, API names win).
#   2. A credential file, default ~/.config/komodo-mcp/credentials, holding
#      KEY=value lines (blank lines and #-comments ignored, quotes optional).
#
# Environment:
#   KOMODO_URL                Core URL (default http://10.0.0.16:9120)
#   KOMODO_MCP_CREDENTIALS    credential file path (see above)
#   KOMODO_MCP_IMAGE          image reference (default the pinned digest below)
#   KOMODO_MCP_ALLOWED_CATEGORIES
#                             tool categories to expose
#                             (default container,server,docker,config)
#   KOMODO_MCP_EXCLUDED_TOOLS tool names to prune from the allowed categories
#                             (default the four mutating container/server tools)
#   KOMODO_MCP_PULL           set to 1 to allow pulling the image if absent
#
# Read-only surface. This server has no read-only mode on stdio: the anonymous
# read-only behaviour described upstream applies only to its HTTP transport,
# and stdio is never authenticated. So the tool surface is a deny-by-default
# category allowlist. Categories mix read and write tools -- allowing
# "container" also allows komodo_container_action -- so the allowlist is
# combined with an explicit exclusion of the four mutating tools in the
# allowed categories. Together they yield exactly the read-only tools listed in
# README.md ("Komodo via MCP"). If the pinned image is ever bumped, re-check
# that no mutating tool slipped into the allowed categories.
#
# Everything this script prints goes to stderr: stdout is the MCP transport and
# must carry protocol frames only.

set -eu

KOMODO_URL=${KOMODO_URL:-http://10.0.0.16:9120}
KOMODO_MCP_IMAGE=${KOMODO_MCP_IMAGE:-ghcr.io/mp-tool/komodo-mcp-server@sha256:3030d0c3f5edaf2023c46856e3fc20961d3dec2d7ce5a1da0b67913397d22edd}
KOMODO_MCP_CREDENTIALS=${KOMODO_MCP_CREDENTIALS:-${HOME:-/nonexistent}/.config/komodo-mcp/credentials}
KOMODO_MCP_ALLOWED_CATEGORIES=${KOMODO_MCP_ALLOWED_CATEGORIES:-container,server,docker,config}
KOMODO_MCP_EXCLUDED_TOOLS=${KOMODO_MCP_EXCLUDED_TOOLS:-komodo_container_action,komodo_server_action,komodo_server_apply,komodo_server_delete}
KOMODO_MCP_PULL=${KOMODO_MCP_PULL:-0}

die() {
	printf 'komodo-mcp: %s\n' "$*" >&2
	exit 2
}

warn() {
	printf 'komodo-mcp: WARNING: %s\n' "$*" >&2
}

# Read one credential value out of the credential file. Parsed rather than
# sourced: the file is data, and this script should not execute it.
read_credential() {
	_want=$1
	[ -r "$KOMODO_MCP_CREDENTIALS" ] || return 1
	while IFS= read -r _line || [ -n "$_line" ]; do
		case $_line in
		'' | '#'*) continue ;;
		esac
		_name=${_line%%=*}
		[ "$_name" = "$_want" ] || continue
		_value=${_line#*=}
		# Trim surrounding whitespace, then one layer of matching quotes.
		_value=$(printf '%s' "$_value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
		case $_value in
		\'*\') _value=$(printf '%s' "$_value" | sed -e "s/^'//" -e "s/'$//") ;;
		\"*\") _value=$(printf '%s' "$_value" | sed -e 's/^"//' -e 's/"$//') ;;
		esac
		printf '%s' "$_value"
		return 0
	done <"$KOMODO_MCP_CREDENTIALS"
	return 1
}

credential_from_file() {
	_want=$1
	[ -r "$KOMODO_MCP_CREDENTIALS" ] || return 1
	_value=$(read_credential "$_want") || return 1
	[ -n "$_value" ] || return 1
	printf '%s' "$_value"
}

# --- resolve credentials ----------------------------------------------------

KOMODO_API_KEY=${KOMODO_API_KEY:-${KOMODO_SERVICE_KEY:-}}
KOMODO_API_SECRET=${KOMODO_API_SECRET:-${KOMODO_SERVICE_SECRET:-}}

if [ -z "$KOMODO_API_KEY" ] || [ -z "$KOMODO_API_SECRET" ]; then
	if [ -e "$KOMODO_MCP_CREDENTIALS" ]; then
		# A credential file readable by anyone but its owner is a bug worth
		# surfacing: this file holds a Komodo API secret.
		_perms=$(stat -c '%a' "$KOMODO_MCP_CREDENTIALS" 2>/dev/null || echo '')
		case $_perms in
		'' | 600 | 400) ;;
		*) warn "$KOMODO_MCP_CREDENTIALS is mode $_perms; it should be 600" ;;
		esac
		[ -n "$KOMODO_API_KEY" ] || KOMODO_API_KEY=$(credential_from_file KOMODO_API_KEY || credential_from_file KOMODO_SERVICE_KEY || true)
		[ -n "$KOMODO_API_SECRET" ] || KOMODO_API_SECRET=$(credential_from_file KOMODO_API_SECRET || credential_from_file KOMODO_SERVICE_SECRET || true)
	fi
fi

if [ -z "$KOMODO_API_KEY" ] || [ -z "$KOMODO_API_SECRET" ]; then
	die "no Komodo credentials found. Set KOMODO_API_KEY and KOMODO_API_SECRET in the
       environment, or create $KOMODO_MCP_CREDENTIALS with mode 600 containing:

           KOMODO_API_KEY=...
           KOMODO_API_SECRET=..."
fi

export KOMODO_URL KOMODO_API_KEY KOMODO_API_SECRET

# --- launch -----------------------------------------------------------------

command -v docker >/dev/null 2>&1 || die "docker not found on PATH"

_pull=never
if [ "$KOMODO_MCP_PULL" = 1 ]; then
	_pull=missing
fi

# -i keeps stdin open for the stdio transport. The credentials are passed by
# name only, so no secret appears in this argv. No --network host: the server
# only needs outbound reach to Komodo Core, which the default bridge provides.
# The filter variables are passed only when non-empty: an empty value is not
# the same as unset, and this server treats an unset allowlist as "allow all".
set -- docker run --rm -i \
	--pull="$_pull" \
	-e MCP_TRANSPORT=stdio \
	-e KOMODO_URL \
	-e KOMODO_API_KEY \
	-e KOMODO_API_SECRET

if [ -n "$KOMODO_MCP_ALLOWED_CATEGORIES" ]; then
	set -- "$@" -e "MCP_TOOLS_ALLOWED_CATEGORIES=$KOMODO_MCP_ALLOWED_CATEGORIES"
fi

if [ -n "$KOMODO_MCP_EXCLUDED_TOOLS" ]; then
	set -- "$@" -e "MCP_TOOLS_EXCLUDED_TOOLS=$KOMODO_MCP_EXCLUDED_TOOLS"
fi

set -- "$@" "$KOMODO_MCP_IMAGE"
exec "$@"
