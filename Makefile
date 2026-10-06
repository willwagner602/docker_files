# docker_files — local and CI entry points.
#
#   make test       run the shell test suite for scripts/health-notify.sh
#   make validate   strict-interpolate both compose stacks (as CI does)
#   make check      both of the above
#   make hooks      install the pre-push hook into .git/hooks (once per clone)
#
# `validate` mirrors what CI runs: it copies each stack's .env.example to .env
# so the required `${VAR:?...}` variables are satisfied, then runs
# `docker compose config`. It uses a throwaway copy under a temp dir, so your
# real .env files are never touched and nothing is left behind.

SHELL := /bin/sh
STACKS := general media

.PHONY: check test validate hooks help

help:
	@echo "Targets:"
	@echo "  make test      Run the health-notify.sh and backup shell test suites"
	@echo "  make validate  Strict-interpolate the compose stacks (general, media)"
	@echo "  make check     test + validate (what CI runs)"
	@echo "  make hooks     Install the pre-push hook into .git/hooks"

test:
	@sh scripts/tests/health-notify/tests.sh
	@sh scripts/tests/backup/tests.sh

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
	  ( cd "$$work/$$stack" && docker compose config -q ) \
	    && printf '  OK  %s\n' "$$stack" \
	    || { printf '  FAIL  %s\n' "$$stack"; exit 1; }; \
	done; \
	printf '\nAll compose stacks validated.\n'

check: test validate

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
