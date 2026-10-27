# docker_files — local and CI entry points.
#
#   make test       run the shell test suite for scripts/health-notify.sh
#   make validate   strict-interpolate the compose stacks (as CI does)
#   make check      both of the above (plus the gdrive drift check on hosts
#                   that have installed copies — CI, which has none, skips it)
#   make hooks      install the pre-push hook into .git/hooks (once per clone)
#
# `validate` mirrors what CI runs: it copies each stack's .env.example (and
# unpoller.env.example, where present) into that stack's scratch .env /
# unpoller.env so the required ${VAR:?...} variables are satisfied, then runs
# `docker compose config`. The example files are the source of truth for
# required variables — add a new ${VAR:?...} to the stack's .env.example and
# every validation path picks it up. It uses a throwaway copy under a temp
# dir, so your real .env files are never touched and nothing is left behind.

SHELL := /bin/sh
STACKS := general media desktop

.PHONY: check test validate hooks help install-gdrive check-gdrive

help:
	@echo "Targets:"
	@echo "  make test      Run the health-notify.sh and backup shell test suites"
	@echo "  make validate  Strict-interpolate the compose stacks (general, media, desktop)"
	@echo "  make check     test + validate, plus the gdrive drift check on hosts with installed copies (CI skips that leg)"
	@echo "  make hooks     Install the pre-push hook into .git/hooks"

test:
	@sh scripts/tests/health-notify/tests.sh
	@sh scripts/tests/backup/tests.sh
	@sh scripts/tests/gdrive-sync/tests.sh
	@sh media/backblaze-wine/tests/tests.sh

validate:
	@set -eu; \
	work=$$(mktemp -d "$${COMPOSE_VALIDATE_TMPDIR:-.}/compose-validate.XXXXXX"); \
	trap 'rm -rf "$$work"' EXIT INT TERM; \
	for stack in $(STACKS); do \
	  printf '\n=== compose validation: %s ===\n' "$$stack"; \
	  cp -R "$$stack" "$$work/$$stack"; \
	  if [ -f "$$stack/.env.example" ]; then \
	    cp "$$stack/.env.example" "$$work/$$stack/.env"; \
	  fi; \
	  for ex in "$$stack"/[!_]*.example; do \
	    [ -f "$$ex" ] || continue; \
	    cp "$$ex" "$$work/$$stack/$$(basename "$$ex" .example)"; \
	  done; \
	  ( cd "$$work/$$stack" && docker compose config -q ) \
	    && printf '  OK  %s\n' "$$stack" \
	    || { printf '  FAIL  %s\n' "$$stack"; exit 1; }; \
	done; \
	printf '\nAll compose stacks validated.\n'

check: test validate
	@if [ -f "$$HOME/.local/bin/gdrive-sync.sh" ]; then make check-gdrive; fi

# This target writes into the user's live bin/config directories. Require a
# deliberate confirmation every time; the mount guard is an additional check.
install-gdrive:
	@set -eu; \
	if [ "$(GDRIVE_INSTALL_CONFIRM)" != "YES" ]; then \
	  echo "Refusing install: rerun with GDRIVE_INSTALL_CONFIRM=YES" >&2; exit 1; \
	fi; \
	if [ "$(GDRIVE_INSTALL)" != "1" ] && [ ! -d /run/media/wbw/Slowby ]; then \
	  echo "not the desktop host — skipped (set GDRIVE_INSTALL=1 to override mount check)"; exit 0; \
	fi; \
	install -d ~/.local/bin ~/.config/systemd/user ~/.config/rclone; \
	install -m 755 scripts/gdrive-sync.sh scripts/gdrive-sync-photos.sh scripts/gdrive-sync-alert.sh ~/.local/bin/; \
	install -Dm 644 systemd/user/gdrive-sync.service systemd/user/gdrive-sync.timer ~/.config/systemd/user/; \
	install -Dm 644 systemd/user/gdrive-sync-photos.service systemd/user/gdrive-sync-photos.timer ~/.config/systemd/user/; \
	install -Dm 644 systemd/user/gdrive-sync-alert.service ~/.config/systemd/user/; \
	install -Dm 644 systemd/user/gdrive-sync-filters.txt ~/.config/rclone/gdrive-sync-filters.txt

# Report drift. Runs as part of make check on hosts that have installed
# copies (skipped on CI, which has none); can also be run standalone.
check-gdrive:
	@set -eu; failed=0; \
	for f in gdrive-sync.sh gdrive-sync-photos.sh gdrive-sync-alert.sh; do \
	  if ! diff -q "scripts/$$f" "$$HOME/.local/bin/$$f" >/dev/null 2>&1; then echo "drift: scripts/$$f -> ~/.local/bin/$$f"; failed=1; fi; \
	done; \
	for f in gdrive-sync.service gdrive-sync.timer gdrive-sync-photos.service gdrive-sync-photos.timer gdrive-sync-alert.service; do \
	  if ! diff -q "systemd/user/$$f" "$$HOME/.config/systemd/user/$$f" >/dev/null 2>&1; then echo "drift: systemd/user/$$f -> ~/.config/systemd/user/$$f"; failed=1; fi; \
	done; \
	if ! diff -q systemd/user/gdrive-sync-filters.txt "$$HOME/.config/rclone/gdrive-sync-filters.txt" >/dev/null 2>&1; then echo "drift: systemd/user/gdrive-sync-filters.txt -> ~/.config/rclone/gdrive-sync-filters.txt"; failed=1; fi; \
	if [ "$$failed" -eq 0 ]; then echo "gdrive install copies match repository"; fi; \
	exit "$$failed"

# Install the pre-push hook. .git/hooks is not tracked by git, so this has to be
# run once per clone. See scripts/hooks/pre-push for what it does and why it
# exists (main has no server-side required status checks — see that file).
hooks:
	@set -eu; \
	hooks_dir=$$(git rev-parse --git-path hooks); \
	mkdir -p "$$hooks_dir"; \
	if [ -e "$$hooks_dir/pre-push" ] && [ ! -L "$$hooks_dir/pre-push" ]; then \
	  case "$$(readlink "$$hooks_dir/pre-push" 2>/dev/null || echo)" in \
	    *scripts/hooks/pre-push) ;; \
	    *) echo "  WARN  $$hooks_dir/pre-push already exists and is not ours; backing up"; \
	       mv "$$hooks_dir/pre-push" "$$hooks_dir/pre-push.bak.$$$$" ;; \
	  esac; \
	fi; \
	ln -sf "$$(cd "$$(dirname "$$hooks_dir")/.." && pwd)/scripts/hooks/pre-push" "$$hooks_dir/pre-push" 2>/dev/null || \
	  { cp scripts/hooks/pre-push "$$hooks_dir/pre-push"; chmod +x "$$hooks_dir/pre-push"; }; \
	chmod +x scripts/hooks/pre-push; \
	printf '  OK  installed %s/pre-push -> scripts/hooks/pre-push\n' "$$hooks_dir"; \
	printf '      (bypass a single push with: git push --no-verify)\n'
