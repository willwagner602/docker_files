#!/bin/sh
# Regression checks for the desktop Google Drive bisync setup.
# Run with: sh scripts/tests/gdrive-sync/tests.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
contains() { grep -Fq -- "$2" "$1"; }

# Launcher versions and source commits must remain immutable.
for f in desktop/mcp-servers/playwright.yaml desktop/mcp-servers/unifi.yaml desktop/mcp-servers/frigate.yaml; do
  if grep -q '@latest' "$REPO/$f"; then bad "mutable MCP source in $f"; else ok "no @latest in $f"; fi
done
contains "$REPO/desktop/mcp-servers/playwright.yaml" '@playwright/mcp@0.0.83' && ok 'Playwright version is pinned' || bad 'Playwright version is pinned'
contains "$REPO/desktop/mcp-servers/unifi.yaml" 'unifi-network-mcp@0.37.2' && ok 'UniFi version is pinned' || bad 'UniFi version is pinned'
grep -Eq 'git\+https://[^" ]+@[0-9a-f]{40}' "$REPO/desktop/mcp-servers/frigate.yaml" && ok 'Frigate commit is pinned' || bad 'Frigate commit is pinned'
contains "$REPO/desktop/mcp-servers/arr-mcp.yml" '@sha256:' && ok 'ARR image is digest-pinned' || bad 'ARR image is digest-pinned'

for pair in 'scripts/gdrive-sync.sh:last-sync.ok' 'scripts/gdrive-sync-photos.sh:last-sync-photos.ok'; do
  script=${pair%%:*}; marker=${pair#*:}
  count=$(grep -Fc "$marker" "$REPO/$script" || true)
  [ "$count" -eq 1 ] && ok "$script writes its marker once" || bad "$script marker count is $count"
  if grep -Fq '[ $? -eq 0 ]' "$REPO/$script"; then bad "$script has dead status guard"; else ok "$script marker is not status-guarded"; fi
  contains "$REPO/$script" '--max-lock 2m --resilient --recover' && ok "$script has recovery flags" || bad "$script lacks recovery flags"
  contains "$REPO/$script" 'gdrive-sync-alert.sh' && ok "$script documents marker consumer" || bad "$script omits marker consumer"
done
contains "$REPO/scripts/gdrive-sync.sh" '--fast-list' && ok 'whole-tree uses --fast-list' || bad 'whole-tree lacks --fast-list'
contains "$REPO/scripts/gdrive-sync.sh" '--checkers=16' && ok 'whole-tree uses --checkers=16' || bad 'whole-tree lacks --checkers=16'
if grep -Fq -- '--fast-list' "$REPO/scripts/gdrive-sync-photos.sh"; then bad 'Photos script should not use --fast-list'; else ok 'Photos script omits --fast-list'; fi
contains "$REPO/systemd/user/gdrive-sync.timer" 'OnCalendar=*-*-* *:0/10:00' && ok 'whole-tree timer cadence pinned' || bad 'whole-tree timer cadence drifted'
contains "$REPO/systemd/user/gdrive-sync-photos.timer" 'OnCalendar=*:*:00' && ok 'photos timer cadence pinned' || bad 'photos timer cadence drifted'
contains "$REPO/scripts/gdrive-sync-photos.sh" 'skipping photos sync.' && ok 'Photos unmounted skip is logged' || bad 'Photos unmounted skip is not logged'
contains "$REPO/scripts/gdrive-sync-alert.sh" 'trust-first fallback' && ok 'alert documents trust-first behavior' || bad 'alert trust-first documentation missing'
contains "$REPO/scripts/gdrive-sync-alert.sh" 'torn write' && ok 'alert documents torn-write limitation' || bad 'alert torn-write documentation missing'
contains "$REPO/desktop/.env.example" 'make validate' && contains "$REPO/desktop/.env.example" '${VAR:?}' && ok 'env placeholder contract is documented' || bad 'env placeholder contract missing'
contains "$REPO/README.md" 'HA_TOKEN' && ok 'README optional env list includes HA_TOKEN' || bad 'README optional env list omits HA_TOKEN'
contains "$REPO/README.md" 'every 60 s' && contains "$REPO/README.md" '≥6 h' && ok 'README describes alarm cadence and threshold' || bad 'README alarm semantics incomplete'
if grep -q 'Electric-header' "$REPO/systemd/user/README.md"; then bad 'garbled README bullet remains'; else ok 'garbled README bullet removed'; fi
contains "$REPO/systemd/user/README.md" 'Argument pass-through' && contains "$REPO/systemd/user/README.md" 'Success marker' && ok 'README separates argument and marker details' || bad 'README detail bullets missing'
contains "$REPO/desktop/mcp-servers/compose.yaml" 'templates' && ok 'MCP fragment template caveat exists' || bad 'MCP fragment caveat missing'
contains "$REPO/desktop/mcp-servers/home-assistant.yaml" 'plaintext HTTP over the LAN' && ok 'Home Assistant transport rationale exists' || bad 'Home Assistant transport rationale missing'
contains "$REPO/systemd/user/README.md" 'last resort' && contains "$REPO/systemd/user/README.md" --recover && ok 'recovery docs describe automatic and manual recovery' || bad 'recovery docs incomplete'
contains "$REPO/systemd/user/README.md" 'shared flock is the' && ok 'overlap guard scope is documented' || bad 'overlap guard scope missing'

contains "$REPO/Makefile" 'install-gdrive:' && contains "$REPO/Makefile" 'check-gdrive:' && ok 'Makefile exposes install and drift targets' || bad 'Makefile targets missing'
contains "$REPO/Makefile" 'GDRIVE_INSTALL_CONFIRM)" != "YES' && ok 'installer requires explicit confirmation' || bad 'installer lacks explicit confirmation'
if grep -A2 '^check:' "$REPO/Makefile" | grep -q 'check-gdrive'; then ok 'drift check runs in make check on installed-copy hosts'; else bad 'drift check is never run by make check'; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
