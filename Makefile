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

.PHONY: check test validate hooks help docker-ro-install docker-ro-uninstall docker-ro-selftest

help:
	@echo "Targets:"
	@echo "  make test      Run the health-notify.sh and docker-ro wrapper test suites"
	@echo "  make validate  Strict-interpolate the compose stacks (general, media)"
	@echo "  make check     test + validate (what CI runs)"
	@echo "  make hooks     Install the pre-push hook into .git/hooks"
	@echo "  make docker-ro-install    Install the docker-ro wrapper on THIS host (needs root)"
	@echo "  make docker-ro-uninstall  Remove the docker-ro wrapper from THIS host (needs root)"

test:
	@sh scripts/tests/health-notify/tests.sh
	@sh scripts/tests/docker-ro/wrapper.sh
	@sh scripts/tests/docker-ro/real-daemon.sh

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

# --- docker-ro restricted-command wrapper -------------------------------------
#
# Installs scripts/docker-ro-wrapper.sh to /usr/local/sbin on THIS host. Run it
# ON the host you want to restrict (media and ha are separate machines, so run
# it on each), as root:
#
#     sudo make docker-ro-install
#
# Why root and why these modes: the wrapper is a security boundary. sshd runs it
# as the login user, so if that user can write the file, the allowlist is
# decorative. Installing it root:root, mode 0755, into root-owned /usr/local/sbin
# means the login user can read and execute it but not modify it.

DOCKER_RO_DEST := /usr/local/sbin/docker-ro-wrapper.sh

docker-ro-selftest:
	@sh scripts/tests/docker-ro/wrapper.sh

docker-ro-install:
	@set -eu; \
	if [ "$$(id -u)" -ne 0 ]; then \
	  echo "  FAIL  must run as root: sudo make docker-ro-install" >&2; exit 1; \
	fi; \
	install -o root -g root -m 0755 scripts/docker-ro-wrapper.sh "$(DOCKER_RO_DEST)"; \
	if [ -n "$$(find "$(DOCKER_RO_DEST)" -perm -o+w -o -perm -g+w 2>/dev/null)" ]; then \
	  echo "  FAIL  $(DOCKER_RO_DEST) is group- or world-writable" >&2; exit 1; \
	fi; \
	sh -n "$(DOCKER_RO_DEST)" || { echo "  FAIL  syntax check" >&2; exit 1; }; \
	printf '  OK  installed %s (root:root 0755)\n' "$(DOCKER_RO_DEST)"; \
	printf '  OK  syntax valid; allowlist verified by: make docker-ro-selftest\n'

docker-ro-uninstall:
	@set -eu; \
	if [ "$$(id -u)" -ne 0 ]; then \
	  echo "  FAIL  must run as root: sudo make docker-ro-uninstall" >&2; exit 1; \
	fi; \
	rm -f "$(DOCKER_RO_DEST)"; \
	printf '  OK  removed %s\n' "$(DOCKER_RO_DEST)"; \
	printf '      Reminder: also delete the docker-ro line from ~/.ssh/authorized_keys,\n'; \
	printf '      otherwise remaining logins will fail with a missing-command error.\n'
