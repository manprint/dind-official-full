# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Docker-in-Docker development image built on `docker:29.8.1-dind`. No application code — the deliverables are two Dockerfiles, two shell entrypoints, three dotfiles, three compose files, and a GitHub Actions release pipeline. Published multi-arch (amd64/arm64) to GHCR as `ghcr.io/manprint/dind-official-full` and `...-full-minimal`.

README is in Italian; container locale/timezone are `it_IT.UTF-8` / `Europe/Rome`.

## Commands

```bash
# full variant, named volumes
docker compose up --build -d
docker compose exec dind bash

# interactive one-shot TTY (entrypoint drops into login shell when stdin is a TTY)
docker compose run --rm dind

# bind-mount variants (host paths overridable)
docker compose -f docker-compose.bind.yml up --build -d
DOCKER_DATA=/path/docker ALPINE_HOME=/path/home docker compose -f docker-compose.bind.yml up -d
docker compose -f docker-compose.minimal.bind.yml up --build -d

# pull a pinned published tag instead of latest
DIND_TAG=1.0.0 docker compose up -d

# lint entrypoints (shellcheck is on the host; shfmt only inside the image)
shellcheck entrypoint.sh entrypoint.minimal.sh

# release: push a tag matching v[0-9]+.[0-9]+.[0-9]+
git tag v1.0.0 && git push origin v1.0.0
```

All three compose files publish `127.0.0.1:2376`, so full and minimal cannot run simultaneously without editing ports. Port 2375 is deliberately not published: while `DOCKER_TLS_CERTDIR` keeps its dind default of `/certs`, dockerd listens on 2376 (TLS) only and nothing ever binds 2375. 2376 is loopback-only because the Docker API is root-equivalent; reaching it from the host also needs `/certs/client`, which no compose file mounts today.

There is no test suite. Verification is manual: bring a variant up, `docker compose exec dind bash`, run `docker info` inside.

## Architecture

### Privilege inversion in the entrypoints

The image ends with `USER alpine` (uid/gid 1000) but `dockerd` must run as root. `entrypoint.sh` / `entrypoint.minimal.sh` resolve this by running as `alpine` and escalating through passwordless sudo (`/etc/sudoers.d/alpine`, written with `!env_reset` so `-E` env passthrough works). `as_root()` is the escalation helper; it no-ops when already uid 0, so the same script works if someone overrides `user: root`.

Argument dispatch at the bottom of both scripts:

- no args, or first arg starts with `-` → launch `dockerd-entrypoint.sh` in the background, wait for `/var/run/docker.sock` (90 × 0.5s), fix socket group/mode, then a login shell as a child (TTY present) or `supervise()`. This is the normal compose path.
- first arg `dockerd` → `exec` the upstream dockerd entrypoint, no background daemon.
- anything else → run it as `alpine` via upstream `docker-entrypoint.sh`.

### PID 1 must stay the entrypoint script

This path never `exec`s. `supervise()` idles in `wait` and the TTY branch uses `run_as_alpine_child`, because an `exec`d `sleep infinity` or `bash -l` becomes a PID 1 with no SIGTERM handler — and the kernel discards unhandled signals sent to PID 1. Previously `docker stop` therefore hung for its full grace period and SIGKILLed dockerd (measured: 10s, exit 137, no `Daemon shutdown complete` in the log), which is what produced the stale state `cleanup_stale_runtime_state()` cleans. `exec` survives only in `run_as_alpine`, used by the two dispatch paths that run a command instead of supervising a daemon.

This is also why all three compose files set `tty: false` / `stdin_open: false`. With a TTY the entrypoint takes the interactive branch, and a **foreground** child blocks trap delivery in POSIX `sh` — PID 1 sits in the shell, the pending SIGTERM is never dispatched, and `docker stop` degrades to SIGKILL again (measured: 10s, exit 137, even with PID 1 correct). `docker compose run` allocates its own TTY, so the interactive path stays reachable there; exiting that shell falls through to `shutdown` explicitly. A `docker stop` aimed at an interactive `compose run` container still needs the SIGKILL fallback — acceptable for an ephemeral `--rm` container.

`shutdown()` on INT/TERM signals dockerd by pidfile through `as_root`, then falls back to `pkill -x dockerd` and waits up to 30s for it to go. It cannot use `$DOCKERD_PID`: because `as_root` is a shell function, `as_root … &` forks a subshell rather than exec'ing, so `$!` is that helper shell, two levels above dockerd — and it is root-owned, so an unprivileged `kill` returns EPERM. Compose files set `stop_grace_period: 60s` to give the daemon room to drain.

Anything in the entrypoints that touches `/run/docker.pid`, `/var/run/docker.pid` or `docker.sock` must go through `as_root`. Those live in root-owned dirs, the scripts run as `alpine`, and every such call is `|| true`-guarded — so a missing `as_root` fails silently and the cleanup becomes a no-op.

`fix_runtime()` relaxes `/certs/client` only. Do not widen `/certs` recursively: the upstream dind entrypoint creates `/certs/ca/key.pem` and `/certs/server/key.pem` at `0600` on purpose, and a readable CA key lets anyone mint client certs the daemon trusts.

### Dotfile seeding and the `dind-env-` marker

Dotfiles are baked into `/etc/skel` and into `/home/alpine` at build time, but `/home/alpine` is a volume — with a bind mount to an empty host dir the baked copies are masked. `prepare_home()` re-seeds them at runtime. `seed_dotfile()` only overwrites when the destination is missing **or** does not contain the string `dind-env-`.

Consequence: `bashrc`, `bash_aliases`, and `profile` each carry a `# dind-env-*` marker comment on line 1–2. Removing it makes the entrypoint clobber the user's customised dotfile on every start. Keep the marker when editing these files.

### Stale-state cleanup

`cleanup_stale_runtime_state()` exists because `/var/lib/docker` and `/home/alpine` persist across container restarts while pidfiles and sockets in them do not correspond to live processes. It kills any pid in `/var/run/docker.pid` or `/run/docker.pid` that is still alive, removes the pidfiles, then removes `docker.sock` only if no live pid claims it. The full variant additionally clears `~/.pm2/*.sock` and `*.pid`.

### Full vs minimal

Same base, same user/sudo/rclone/fuse/bind-mount logic, same dotfiles. The full variant adds Rust, Go, C/C++ toolchain, Node/npm, Java 21, a Python venv at `/opt/venv` (prepended to `PATH`), GitHub CLI, and globally-installed `prettier eslint typescript @angular/cli pm2 pm2-logrotate`.

Both variants deliberately install `coreutils` and `tar` to displace the busybox applets. Alpine's `tar` package overwrites `/bin/tar` — the busybox symlink — with the real GNU binary, so there is no PATH-order subtlety and no `/usr/bin/tar`. Neither package is redundant: dropping them silently reverts `tar` to busybox 1.37 (no `--sort`, `--xattrs`, `--owner`/`--group`, `--wildcards`) and `ls`/`dircolors`/`date` to the busybox versions. `busybox tar` still works if the applet is ever needed explicitly.

PM2 exists only in the full variant, and only there does the entrypoint call `start_pm2()`: ping, `pm2 resurrect` if `~/.pm2/dump.pm2` is non-empty, install/configure `pm2-logrotate`, `pm2 save`. The Dockerfile pre-seeds a configured `.pm2` into `/etc/skel/.pm2` (installed, configured, killed, sockets stripped) so a fresh bind-mounted home gets working logrotate settings without a first-run install.

Changes to shared behaviour must be applied to **both** entrypoints and **both** Dockerfiles — they are duplicated, not shared.

### Build context

`.dockerignore` is deny-everything-then-allowlist. Any new file that a Dockerfile `COPY`s must be added to it explicitly or the build fails with "file not found".

### Release pipeline (`.github/workflows/release.yml`)

Tag `vX.Y.Z` triggers:

1. `build` — 4 jobs (full/minimal × amd64 on `ubuntu-24.04` / arm64 on `ubuntu-24.04-arm`, native runners, no QEMU). Each pushes by digest only (`push-by-digest=true`, no tag) and uploads the digest as an artifact. GHA cache is scoped per variant+platform.
2. `merge` — per variant, `docker buildx imagetools create` assembles the manifest list from the digests and applies the semver/`latest` tags.
3. `release` — rewrites `docker-compose.bind.yml` and `docker-compose.minimal.bind.yml` with an inline Python script that **strips the `build:` block and pins `image:` to the released version**, then attaches those plus the unmodified `docker-compose.yml` and both Dockerfiles to the GitHub Release.

That stamping script is indentation-sensitive: it detects `    build:` (4 spaces) and skips following lines indented deeper than 4 spaces, and rewrites any line starting with `    image:`. Re-indenting the `dind` service in the bind compose files silently breaks the release artifacts. `docker-compose.yml` is published as-is, still carrying its `build:` block.

Repo name is interpolated into the image name and lowercased in CI, so the image path follows `github.repository` — not a hardcoded value.
