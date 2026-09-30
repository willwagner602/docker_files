# docker-health-access.md

How to give an automated agent **read-only** Docker visibility on the `wbw-media`
and `wbw-ha` hosts, without handing it root and without letting it read secrets
out of container logs.

This document exists because the obvious answers are wrong in two specific ways,
both of which were measured rather than assumed:

1. **You cannot make an existing key read-only.** `command=` and `restrict` are
   per-key properties in `authorized_keys`. Applying them to `wbw`'s `id_rsa`
   would lock the human's own logins into the wrapper. A restricted key must be a
   key used *only* by the restricted party.
2. **`wbw` is not a low-privilege account.** It is in both `docker` and `sudo`.
   Docker group membership is root-equivalent on its own (`docker run
   --privileged -v /:/host` escapes to host root), so any key accepted for `wbw`
   confers root — there is no version of "log in as wbw but read-only" that is
   actually enforced.

Hence: a dedicated key, restricted by `command=`, enforced by `sshd` before any
shell exists.

---

## The short version

1. Generate a dedicated `ed25519` keypair (private key never leaves the agent's
   machine).
2. Install `scripts/docker-ro-wrapper.sh` on each host as **root:root, mode 0755**.
3. Append one `command="..."` line to `~/.ssh/authorized_keys` on each host.
4. Agent connects with `ssh -i <key> wbw@<host> <subcommand>`.

Everything below is the detail, including what this does *not* protect against.

---

## 1. Why the wrapper is a whitelist, not a redactor

This was the most interesting part of the work, and it is worth reading before
you tune anything.

Container logs are where secrets actually show up: `media/.env` values, Plex
claim tokens, Telegram bot tokens, API keys. So the question "can I grant log
access without granting secret access?" has a tempting answer — scrub the logs —
and that answer is **wrong**.

### `docker logs` cannot redact

Verified against a real daemon (Docker 29.8.0): `docker logs --help` exposes only
`--since`, `--tail`, `--timestamps`, and `--details`. There is no redaction or
filtering flag. Any redaction must be done by us, downstream.

### A regex scrubber is only partially effective

A `KEY=value` scrubber was tested against a container emitting secret-shaped
lines. It caught the easy shapes and missed others:

| input | scrubbed? |
|---|---|
| `PLEX_CLAIM_TOKEN=claim-...` | yes |
| `PASSWORD=hunter2` | yes |
| `API_KEY=sk-live-...` | yes |
| `Authorization: Bearer eyJ...` | yes |
| `---BEGIN PRIVATE KEY---` block | yes (header only) |
| `pass=correcthorsebatterystaple` | **no** |
| `my_pw=hunter2` | **no** |
| `token is claim-nxB1x...` (prose) | **no** |
| `Authorization: Basic dXNlcjpwYXNz` | **partially** — payload leaked |

A scrubber that silently misses cases is **worse than no scrubber**, because it
invites trust it has not earned. The miss list is unbounded; you cannot enumerate
every way a log line might contain a secret.

### So: drop unknown lines instead of scrubbing them

`logs <id>` emits **only lines matching diagnostic patterns** and discards
everything else:

```
error|fail|fatal|warn|exception|critical|panic|traceback|timeout|timed out|
refused|unreachable|unhealthy|health|restart|killed|oom|out of memory|denied|
forbidden|retry|retrying|crash|segfault|not found|no such|unable to|cannot|
could not|exited
```

Verified on a real container whose logs contained three secrets:

```
$ ssh -i <key> wbw@media logs dro-test2
ERROR: upstream refused connection
warning: retry attempt 1
```

The three secret-bearing lines are **absent** — not masked, dropped. This is the
whitelist property: a secret can only leak if it appears on a line that also
contains a diagnostic keyword.

**The tradeoff, stated plainly:** you lose benign context lines. A log line that
is useful but contains none of those keywords will not appear. That is the price
of the guarantee, and it is the right price when the alternative is partial
redaction you have to trust.

### Raw logs are opt-in

`logs-raw <id>` exists but is **refused by default**. It requires
`ALLOW_RAW_LOGS=1` in the environment. Treat enabling it as a deliberate,
temporary act — it restores the full leak surface described above.

---

## 2. What the allowlist permits

| subcommand | runs | notes |
|---|---|---|
| `ps` | `docker ps -a --no-trunc` | |
| `images` | `docker image ls --digests --no-trunc` | digests, for pinning work |
| `version` | `docker version` | client + server |
| `info` | `docker info` | **weakest entry** — includes container names/paths |
| `inspect <id>` | `docker inspect <id>` | |
| `health <id>` | `docker inspect --format '{{json .State.Health}}'` | health verdict **without** log tail |
| `config <id>` | `docker inspect --format '{{json .Config}}'` | |
| `logs <id>` | `docker logs --tail 200` → diagnostic whitelist | |
| `logs-raw <id>` | unfiltered logs | disabled unless `ALLOW_RAW_LOGS=1` |
| `help` | prints the allowlist | |

### What is excluded, and why

`run`, `create`, `start`, `stop`, `restart`, `kill`, `rm`, `exec`, `cp`, `save`,
`export`, `load`, `system`, `plugin`, `context`, `build`, `push`, `pull`,
`login`, `secret`, `node`, `swarm` — every write verb and every host-escape verb.

`docker exec` and `docker run` are the escape hatches; they are never reachable
here. This matters because the wrapper's job is to be safe *even though* the
underlying account is root — the restriction is on the command surface, not on
the Unix privileges.

### No argument passthrough

The wrapper takes **one** subcommand and **at most one** validated id. There is
no general argument passthrough, deliberately:

> Shell and sudoers rules that match "the whole command line as a string" are a
> classic root-shell footgun. A trailing wildcard like `docker ps *` also matches
> `docker ps --config /tmp/evil`, because the flag is just more argument text.

This is why a sudoers-based approach was rejected in favour of `command=`. Here
the allowlist is a fixed set of literal strings plus a closed set of
regex-validated ids, so there is no argument-matching subtlety to get wrong.

Concretely, `docker inspect --format '{{.Config}}' foo` is **rejected** (two
arguments). If a format string turns out to matter, add a *named* subcommand —
`config <id>` already covers the common case — rather than opening passthrough.

Ids are validated as either a 12–64 char lowercase hex id, or an image reference
(`[a-z0-9._/-]+` with optional `:tag` and `@sha256:` digest). Leading `-`
(rejected, would parse as a flag), whitespace, shell metacharacters, and `..`
traversal are all refused.

---

## 3. Installation

### Step 1 — generate the keypair (on the agent's machine)

```bash
ssh-keygen -t ed25519 -N '' \
  -C 'docker-ro@<purpose>' \
  -f ~/.ssh/docker_ro
chmod 600 ~/.ssh/docker_ro
```

No passphrase, because the key is used non-interactively. **The restriction is
what contains the risk, not the passphrase** — this is the central design
decision, so do not skip step 3.

### Step 2 — install the wrapper (on each host, as root)

```bash
# from the repo checkout on the host:
sudo make docker-ro-install
```

That target copies `scripts/docker-ro-wrapper.sh` to
`/usr/local/sbin/docker-ro-wrapper.sh`, sets **root:root 0755**, refuses to
install if the file ends up group- or world-writable, and runs a syntax check.

If the repo is not checked out there:

```bash
sudo install -o root -g root -m 0755 docker-ro-wrapper.sh \
  /usr/local/sbin/docker-ro-wrapper.sh
```

> **Why ownership matters.** `sshd` runs the wrapper as the login user. If that
> user can write the file, the allowlist is decorative — they can simply edit it.
> Root-owned and not group/world-writable is what makes the check real. The
> install target enforces this; a manual `cp` does not.

### Step 3 — authorize the key (on each host)

Append to `~/.ssh/authorized_keys` — **one line** (wrapping below is cosmetic):

```
command="/usr/local/sbin/docker-ro-wrapper.sh",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding,restrict ssh-ed25519 AAAA... docker-ro@<purpose>
```

This is a **new line**. It does not modify the existing `id_rsa` entry, so the
human's own access is untouched.

What each option does:

| option | effect |
|---|---|
| `command="..."` | `sshd` runs the wrapper instead of a shell |
| `restrict` | disables PTY, forwarding, agent, X11, and more (the blanket) |
| `no-pty` + the rest | belt-and-braces restatement; explicit beats implicit |

### Step 4 — verify

From the agent's machine:

```bash
ssh -i ~/.ssh/docker_ro wbw@10.0.0.181 ps       # expect a container list
ssh -i ~/.ssh/docker_ro wbw@10.0.0.181 run      # expect rc=64, refused
ssh -i ~/.ssh/docker_ro wbw@10.0.0.181 logs <c> # expect diagnostics only
```

The wrapper's own test suites are the systematic version of this:

```bash
make docker-ro-selftest   # stub-docker allowlist suite (52 assertions)
make test                 # also runs the real-daemon suite (17 assertions)
```

### Uninstalling

```bash
sudo make docker-ro-uninstall   # removes the wrapper
```

Then delete the `command="..."` line from `authorized_keys`. Do both — leaving
the line with the wrapper gone makes those logins fail with a missing-command
error.

---

## 4. Verification performed

Both suites run as part of `make check`. Every claim above that could be tested
against reality was.

| suite | assertions | what it proves |
|---|---|---|
| `scripts/tests/docker-ro/wrapper.sh` | 52 | allowlist boundary: allowed verbs reach docker, every write/escape verb refused, argument injection refused (metacharacters, traversal, `$(...)`, backticks, leading `-`), `logs` filters secrets, `logs-raw` gated |
| `scripts/tests/docker-ro/real-daemon.sh` | 17 | against a **real daemon**: binary resolution works, `logs` keeps diagnostics and drops real secrets from real container output, refused verbs leave the container untouched |

The stub suite **skips nothing**; the real-daemon suite skips cleanly (exit 0)
if no daemon is reachable, so `make check` stays usable on machines without
Docker.

### A bug that only the real-daemon suite caught

An earlier revision hardcoded `DOCKER=/usr/bin/docker` with an `/usr/local/bin`
fallback. The stub suite passed — because the stub suite *rewrote those paths*.
On this dev box, which uses the snap package, the wrapper failed at runtime with
`docker CLI not found`, and every subcommand returned rc=127.

The wrapper now resolves via `resolve_docker()`, probing absolute locations
(`/usr/bin`, `/usr/local/bin`, `/snap/bin`, `/usr/sbin`) before falling back to
`PATH`, and refuses a CLI resolved under `$HOME` (a caller-controlled `docker`
binary is a root shell wearing the allowlist as a costume).

This is the general lesson, and the reason both suites exist: **stub tests prove
the logic, not the environment.** The stub suite could not have caught this,
because it exists to replace the very thing that was broken.

---

## 5. What this does NOT protect against

Being explicit, because the design invites over-trust:

- **It does not reduce the account's Unix privileges.** `wbw` is still in
  `docker` and `sudo`. If the agent's key is used for *anything* outside the
  wrapper, the restriction does not apply. The wrapper constrains the `command=`
  key only.
- **Logs can still leak, on diagnostic lines.** A secret appearing on a line
  containing `error`/`fail`/`warn`/etc. will pass the filter. The whitelist
  shrinks the surface; it does not eliminate it.
- **`info` is the weakest entry.** It reports container names and paths. Drop it
  from the `case` block if that matters.
- **No write access, by design.** Verifying self-healing behaviour (autoheal
  restarting a container) needs one deliberate write — a `restart`. That is
  intentionally *not* in the baseline and should be granted narrowly and
  temporarily, or performed by a human.
- **The key has no passphrase.** Mitigated by `command=` + `restrict`, not by
  SSH. If the private key file leaks, the holder can run the allowlisted read
  commands on both hosts until you remove the `authorized_keys` line.
- **Not tested on `wbw-media` / `wbw-ha`.** Everything here was verified against
  a local daemon (Docker 29.8.0) and the stub suite. The hosts have not been
  touched; the first on-host step is to re-run `make docker-ro-selftest` and the
  three verification commands in step 4.

---

## 6. Files

| file | role |
|---|---|
| `scripts/docker-ro-wrapper.sh` | the allowlist wrapper — the `command=` target |
| `scripts/tests/docker-ro/wrapper.sh` | stub-docker suite: allowlist boundary |
| `scripts/tests/docker-ro/real-daemon.sh` | real-daemon suite: filter + resolution |
| `Makefile` | `docker-ro-install`, `docker-ro-uninstall`, `docker-ro-selftest`; `make check` runs both suites |

---

## 7. Related hardening (not done here)

`media/autoheal.yml` mounts `/var/run/docker.sock` **read-write**, while every
other socket consumer in this repo (`general/health-notify-general.yml`,
`media/health-notify-media.yml`) uses a `socket-proxy` sidecar with the socket
`:ro`. autoheal must restart containers, so it cannot use a read-only proxy —
but socket-proxy supports scoped permissions, so a dedicated proxy exposing only
the endpoints autoheal needs is a real hardening step. Tracked separately; it
also carries the risk of silently breaking self-healing, so it needs a live
restart test.

Note the interaction with this document: if autoheal's socket access is
restricted by *proxy permissions*, that is enforced at the Docker API layer for
everyone hitting that proxy. The `command=` wrapper here is enforced at the SSH
layer for one key. They are complementary, not redundant.
