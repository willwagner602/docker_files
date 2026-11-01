# CI base image for the Forgejo runner on this host.
#
# The runner label map points the docker/self-hosted labels at this image.
# It bundles every toolchain the migrated workflows need so jobs can run
# plain commands instead of setup-go/setup-node actions:
#   - Go 1.26 (oldest go.mod in the org is 1.23; newer toolchains compile it)
#   - Node.js 22 LTS (matches .nvmrc and web engines >=22 <23)
#   - docker CLI + compose + buildx plugins (jobs drive the host daemon
#     through the automounted socket)
# Rebuild after changing this file: docker build -t forgejo-ci-base:latest .
FROM golang:1.26-bookworm

ARG NODE_MAJOR=22
ARG DOCKER_VERSION=28.5.2
ARG COMPOSE_VERSION=v5.6.1
ARG BUILDX_VERSION=v0.30.0

# Node.js LTS from NodeSource; git and curl already ship with the golang image.
# jq + python3 + sqlite3: required by scripts/health-notify.sh and the backup
# test suites (CI runs them inside the job container).
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs jq python3 sqlite3 \
    && rm -rf /var/lib/apt/lists/*

# docker CLI client and CLI plugins (compose, buildx).
# download.docker.com uses uname-style arches (x86_64); the GitHub release
# assets for compose/buildx use dpkg-style arches (amd64).
RUN set -eu \
    && uarch="$(uname -m)" \
    && darch="$(dpkg --print-architecture)" \
    && curl -fsSL "https://download.docker.com/linux/static/stable/${uarch}/docker-${DOCKER_VERSION}.tgz" \
    | tar -xz -C /usr/local/bin --strip-components=1 docker/docker \
    && mkdir -p /usr/local/lib/docker/cli-plugins \
    && curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${uarch}" \
    -o /usr/local/lib/docker/cli-plugins/docker-compose \
    && curl -fsSL "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-${darch}" \
    -o /usr/local/lib/docker/cli-plugins/docker-buildx \
    && chmod +x /usr/local/lib/docker/cli-plugins/* /usr/local/bin/docker
