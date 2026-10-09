#!/bin/sh
# Probe a Komodo API key to discover which read operations it can actually
# perform.
#
# Komodo API keys carry no permissions of their own. A key inherits the
# permissions of the user it belongs to, and the API offers no way to read
# those permissions back as a simple list. So the only reliable answer to
# "what can this key do?" is to call each read endpoint and observe the
# result. That is what this script does.
#
# Usage:
#   sh scripts/komodo-probe.sh
#
# Credentials are read from the environment: KOMODO_API_KEY / KOMODO_API_SECRET,
# or KOMODO_SERVICE_KEY / KOMODO_SERVICE_SECRET (both accepted, API names win).
# They may instead be placed in an env file (see KOMODO_ENV_FILE). The script
# reads the values from the environment or a file; it never writes them out.
#
# Environment:
#   KOMODO_URL            Core URL (default http://10.0.0.16:9120)
#   KOMODO_SERVER         server name for container probes (default general)
#   KOMODO_PROBE_TIMEOUT  per-request timeout in seconds (default 15)
#   KOMODO_ENV_FILE       file to read credentials from (default general/.env)
#   KOMODO_PROBE_KEEP     set to 0 to delete response bodies on exit
#
# The secret is never printed. Response bodies are truncated; log tails are
# deliberately not fetched in full (see the GetContainerLog probe).

set -u

KOMODO_URL=${KOMODO_URL:-http://10.0.0.16:9120}
# Accept both naming conventions. KOMODO_SERVICE_KEY / KOMODO_SERVICE_SECRET are
# what this machine's shell exports; KOMODO_API_KEY / KOMODO_API_SECRET is what
# the Komodo API calls them. Prefer the API names when both are set.
KOMODO_API_KEY=${KOMODO_API_KEY:-${KOMODO_SERVICE_KEY:-}}
KOMODO_API_SECRET=${KOMODO_API_SECRET:-${KOMODO_SERVICE_SECRET:-}}
KOMODO_SERVER=${KOMODO_SERVER:-general}
TIMEOUT=${KOMODO_PROBE_TIMEOUT:-15}

# If the credentials are not already in the environment, read them from an
# env file. The file is parsed for the two keys rather than sourced, so
# nothing in it is executed. Defaults to general/.env, which is gitignored
# and already holds this deployment's Komodo secrets.
ENV_FILE=${KOMODO_ENV_FILE:-general/.env}

read_env_key() {
  [ -f "$ENV_FILE" ] || return 1
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$ENV_FILE" \
    | tail -1 \
    | sed 's/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//'
}

if [ -z "$KOMODO_API_KEY" ]; then
  KOMODO_API_KEY=$(read_env_key KOMODO_API_KEY 2>/dev/null || true)
  [ -n "$KOMODO_API_KEY" ] || KOMODO_API_KEY=$(read_env_key KOMODO_SERVICE_KEY 2>/dev/null || true)
fi
if [ -z "$KOMODO_API_SECRET" ]; then
  KOMODO_API_SECRET=$(read_env_key KOMODO_API_SECRET 2>/dev/null || true)
  [ -n "$KOMODO_API_SECRET" ] || KOMODO_API_SECRET=$(read_env_key KOMODO_SERVICE_SECRET 2>/dev/null || true)
fi

if [ -z "$KOMODO_API_KEY" ] || [ -z "$KOMODO_API_SECRET" ]; then
  echo "FATAL: no Komodo credentials found." >&2
  echo "  Set KOMODO_API_KEY and KOMODO_API_SECRET (KOMODO_SERVICE_KEY and" >&2
  echo "  KOMODO_SERVICE_SECRET are also accepted), or add them to $ENV_FILE" >&2
  echo "  (or point KOMODO_ENV_FILE at another file)." >&2
  exit 2
fi

outdir=$(mktemp -d "${TMPDIR:-/tmp}/komodo-probe.XXXXXX") || exit 2

# Response bodies are kept for inspection by default; set KOMODO_PROBE_KEEP=0
# to clean up automatically.
if [ "${KOMODO_PROBE_KEEP:-1}" = "0" ]; then
  trap 'rm -rf "$outdir"' EXIT INT TERM
fi

# call <slug> <json-body> -> writes body to $outdir/<slug>.json, echoes status
call() {
  slug=$1
  body=$2
  curl -sS -m "$TIMEOUT" -o "$outdir/$slug.json" -w '%{http_code}' \
    -X POST "$KOMODO_URL/read" \
    -H "X-Api-Key: $KOMODO_API_KEY" \
    -H "X-Api-Secret: $KOMODO_API_SECRET" \
    -H 'Content-Type: application/json' \
    --data "$body" 2>"$outdir/$slug.err" || echo 000
}

# report <slug> <label> <expected-permission>
report() {
  slug=$1
  label=$2
  expect=$3
  f="$outdir/$slug.json"
  code=$(cat "$outdir/$slug.code" 2>/dev/null || echo "?")

  note=""

  if [ "$code" = "200" ] && ! jq -e 'has("error")' "$f" >/dev/null 2>&1; then
    verdict="ALLOWED"
    # Komodo answers a read of a resource type the key cannot access with an
    # empty array rather than a permission error (moghtech/komodo#1594). A
    # zero-length array is therefore ambiguous - "none exist" and "not
    # permitted" are indistinguishable to the client - so it is flagged
    # instead of being allowed to read as a clean pass.
    n=$(jq -r 'if type=="array" then length else empty end' "$f" 2>/dev/null)
    if [ "$n" = "0" ]; then
      verdict="EMPTY "
      note="0 items: no permission OR none exist (indistinguishable)"
    elif [ -n "$n" ]; then
      note="$n item(s)"
    fi
  elif [ "$code" = "200" ]; then
    verdict="DENIED "
  else
    verdict="HTTP $code"
  fi

  printf '%-6s %-24s %-28s %s\n' "$verdict" "$label" "$expect" "$code"

  # Show a short reason for anything that was not plainly allowed.
  if [ -n "$note" ]; then
    printf '         -> %s\n' "$note"
  elif [ "$verdict" != "ALLOWED" ]; then
    msg=$(jq -r '.error // .message // empty' "$f" 2>/dev/null | head -c 200)
    [ -n "$msg" ] && printf '         -> %s\n' "$msg"
  fi
}

printf 'Komodo read-permission probe\n'
printf '  core:   %s\n' "$KOMODO_URL"
printf '  server: %s\n' "$KOMODO_SERVER"
printf '  key:    %s (secret withheld)\n\n' "$(printf '%s' "$KOMODO_API_KEY" | head -c 6)..."

# Preflight: confirm the credentials work at all before running the full
# sweep. Komodo locks out an IP after 5 auth failures, so discovering a bad
# key mid-probe would produce a wall of misleading 429s.
pf_code=$(call preflight '{"type":"GetVersion","params":{}}')
if [ "$pf_code" != "200" ]; then
  echo "FATAL: credentials rejected before probing (HTTP $pf_code)." >&2
  jq -r '.error // .message // empty' "$outdir/preflight.json" 2>/dev/null \
    | sed 's/^/  /' >&2
  echo "  Check: the key/secret are correct, and the user is ENABLED in Komodo" >&2
  echo "  (Settings -> Users -> the user -> Enable User)." >&2
  echo "  A 429 here means the IP is temporarily locked out; wait ~15s." >&2
  exit 1
fi

printf '%-6s %-24s %-28s %s\n' "RESULT" "REQUEST" "EXPECTED PERMISSION" "HTTP"
printf -- '--------------------------------------------------------------------------\n'

# --- Baseline: needs no resource permission -------------------------------
call getversion '{"type":"GetVersion","params":{}}' > "$outdir/getversion.code"
report getversion "GetVersion" "none (baseline)"

call getusername '{"type":"GetUsername","params":{}}' > "$outdir/getusername.code"
report getusername "GetUsername" "none (self)"

# ListPermissions returns the calling user's own direct permissions. This is
# the authoritative answer, and it also disambiguates the EMPTY results below:
# a resource type absent here is genuinely not permitted, not merely unused.
# Caveat: it omits permissions inherited from UserGroups.
call listpermissions '{"type":"ListPermissions","params":{}}' > "$outdir/listpermissions.code"
report listpermissions "ListPermissions" "none (self)"

if [ "$(cat "$outdir/listpermissions.code")" = "200" ]; then
  printf '\nPermissions granted to this user directly:\n'
  jq -r 'if type=="array" and length>0 then
           .[] | "  - \(.user_target.type // "?") \(.user_target.id // "?")  \(.resource_target.type // "*") \(.resource_target.id // "all")  \(.level)"
         elif type=="array" then "  (none - permissions are inherited from a UserGroup)"
         else "  (unexpected shape)" end' "$outdir/listpermissions.json" 2>/dev/null | head -40
fi

# --- Server-scoped ---------------------------------------------------------
call listservers '{"type":"ListServers","params":{"page":0,"limit":0}}' > "$outdir/listservers.code"
report listservers "ListServers" "Server: Read"

call serverssummary '{"type":"GetServersSummary","params":{}}' > "$outdir/serverssummary.code"
report serverssummary "GetServersSummary" "Server: Read"

call getserver "{\"type\":\"GetServer\",\"params\":{\"server\":\"$KOMODO_SERVER\"}}" > "$outdir/getserver.code"
report getserver "GetServer" "Server: Read"

call sysinfo "{\"type\":\"GetSystemInformation\",\"params\":{\"server\":\"$KOMODO_SERVER\"}}" > "$outdir/sysinfo.code"
report sysinfo "GetSystemInformation" "Server: Read"

# --- Container listing -----------------------------------------------------
call listall '{"type":"ListAllContainers","params":{"limit":0}}' > "$outdir/listall.code"
report listall "ListAllContainers" "Server: Read"

call listcontainers "{\"type\":\"ListContainers\",\"params\":{\"server\":\"$KOMODO_SERVER\"}}" > "$outdir/listcontainers.code"
report listcontainers "ListContainers" "Server: Read"

call containerssummary '{"type":"GetContainersSummary","params":{}}' > "$outdir/containerssummary.code"
report containerssummary "GetContainersSummary" "Server: Read"

call listnetworks "{\"type\":\"ListNetworks\",\"params\":{\"server\":\"$KOMODO_SERVER\"}}" > "$outdir/listnetworks.code"
report listnetworks "ListNetworks" "Server: Read"

# --- Specifics: Inspect and Logs are SEPARATE from Read --------------------
container=$(jq -r '.[0].name // .containers[0].name // empty' "$outdir/listcontainers.json" 2>/dev/null | head -1)
if [ -z "$container" ]; then
  container=$(jq -r '.[0].name // .containers[0].name // empty' "$outdir/listall.json" 2>/dev/null | head -1)
fi

if [ -n "$container" ]; then
  printf '\n  (probing container-specific endpoints against: %s)\n' "$container"

  call inspect "{\"type\":\"InspectContainer\",\"params\":{\"server\":\"$KOMODO_SERVER\",\"container\":\"$container\"}}" > "$outdir/inspect.code"
  report inspect "InspectContainer" "Server: Read + Inspect"

  # tail=1: enough to prove access without pulling a full log body.
  call getlog "{\"type\":\"GetContainerLog\",\"params\":{\"server\":\"$KOMODO_SERVER\",\"container\":\"$container\",\"tail\":1}}" > "$outdir/getlog.code"
  report getlog "GetContainerLog" "Server: Read + Logs"
else
  printf '\n  (no container name found; skipping Inspect/Logs probes)\n'
fi

# --- Stack-scoped: known to expose .env values ----------------------------
printf '\n'
call liststacks '{"type":"ListStacks","params":{"page":0,"limit":0}}' > "$outdir/liststacks.code"
report liststacks "ListStacks" "Stack: Read (SENSITIVE)"

call stackssummary '{"type":"GetStacksSummary","params":{}}' > "$outdir/stackssummary.code"
report stackssummary "GetStacksSummary" "Stack: Read (SENSITIVE)"

# --- Other resource types --------------------------------------------------
printf '\n'
call listvariables '{"type":"ListVariables","params":{}}' > "$outdir/listvariables.code"
report listvariables "ListVariables" "Variable access"

call listusers '{"type":"ListUsers","params":{}}' > "$outdir/listusers.code"
report listusers "ListUsers" "admin"

call listusergroups '{"type":"ListUserGroups","params":{}}' > "$outdir/listusergroups.code"
report listusergroups "ListUserGroups" "admin"

# --- Server count: does one key cover both hosts? --------------------------
printf '\nServers visible to this key:\n'
jq -r 'if type=="array" then .[] | "  - \(.name)  (\(.state // "unknown"))" else "  (none or unexpected shape)" end' \
  "$outdir/listservers.json" 2>/dev/null | head -20

printf '\nDone. Bodies retained at: %s\n' "$outdir"
printf 'Copy anything you need before this shell exits (the dir is removed on exit).\n'
