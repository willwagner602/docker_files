# docker_files — local and CI entry points.
#
#   make test       run the shell test suite for scripts/health-notify.sh
#   make validate   strict-interpolate both compose stacks (as CI does)
#   make check      both of the above
#
# `validate` mirrors what CI runs: it copies each stack's .env.example to .env
# so the required `${VAR:?...}` variables are satisfied, then runs
# `docker compose config`. It uses a throwaway copy under a temp dir, so your
# real .env files are never touched and nothing is left behind.

SHELL := /bin/sh
STACKS := general media

.PHONY: check test validate help

help:
	@echo "Targets:"
	@echo "  make test      Run the health-notify.sh shell test suite"
	@echo "  make validate  Strict-interpolate the compose stacks (general, media)"
	@echo "  make check     test + validate (what CI runs)"

test:
	@sh scripts/tests/health-notify/tests.sh

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
