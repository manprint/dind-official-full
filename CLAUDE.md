# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Docker-in-Docker development image built on `docker:29.8.2-dind`. No application code — the deliverables are two Dockerfiles, two shell entrypoints, three dotfiles, three compose files, a smoke test, and a GitHub Actions release pipeline. Published multi-arch (amd64/arm64) to GHCR as `ghcr.io/manprint/dind-official-full` and `...-full-minimal`. It isolates staging environments, so coming back unattended after a hard stop (power loss, host crash) is a hard requirement, not a nicety.

README is in Italian; container locale/timezone are `it_IT.UTF-8` / `Europe/Rome`.

## Commands

```bash
# the compose files have no build: block, they run ghcr.io/manprint/dind-official-full[-minimal]:$DIND_TAG;
# build locally under those names first (docker compose up -d then uses the local image, no pull)
just build            # or build-full / build-minimal; build-clean = no cache

# full variant, named volumes
docker compose up -d
docker compose exec dind bash

# interactive one-shot TTY (entrypoint drops into login shell when stdin is a TTY)
docker compose run --rm dind

# bind-mount variants (host paths overridable)
docker compose -f docker-compose.bind.yml up -d
DOCKER_DATA=/path/docker ALPINE_HOME=/path/home docker compose -f docker-compose.bind.yml up -d
docker compose -f docker-compose.minimal.bind.yml up -d

# a second instance next to the first: own project, name, port, data and (DIND_NET_SUBNET/DIND_IPV4/DIND_NET_GATEWAY) network
DIND_NAME=dind-b DIND_TLS_PORT=2377 DIND_NET_SUBNET=10.10.161.0/24 DIND_IPV4=10.10.161.1 DIND_NET_GATEWAY=10.10.161.254 DOCKER_DATA=/path/b/docker ALPINE_HOME=/path/b/home \
  docker compose -p dind-b -f docker-compose.bind.yml up -d

# pull a pinned published tag instead of latest
DIND_TAG=1.0.0 docker compose up -d

# lint (shellcheck is on the host; shfmt only inside the image)
shellcheck entrypoint.sh entrypoint.minimal.sh tests/smoke.sh

# smoke test a built image (needs --privileged)
docker build -t dind-test . && tests/smoke.sh dind-test 3

# release: push a tag matching v[0-9]+.[0-9]+.[0-9]+
git tag v1.0.0 && git push origin v1.0.0
```

Compose variables: `DIND_TAG` (image tag), `DIND_NAME` (container name), `DIND_TLS_PORT` (host port for 2376), `DIND_DNS` (resolvers for the inner containers), `DOCKER_DAEMON_INTERNAL_BIP` (subnet of the inner `docker0`), `DIND_ENVIRONMENT_NAME` (label in the shell prompt), `DIND_NET_SUBNET` / `DIND_IPV4` / `DIND_NET_GATEWAY` (the compose network, default 10.10.160.0/24, container on .1, gateway on .254 because .1 is the bridge's usual gateway), and in the bind variants `DOCKER_DATA` / `ALPINE_HOME`.

Port 2375 is deliberately not published: while `DOCKER_TLS_CERTDIR` keeps its dind default of `/certs`, dockerd listens on 2376 (TLS) only and nothing ever binds 2375. 2376 is loopback-only because the Docker API is root-equivalent; reaching it from the host also needs `/certs/client`, which no compose file mounts today.

All three compose files also set `restart: unless-stopped`, `stop_grace_period: 60s`, a `docker version` healthcheck, json-file rotation (10m × 5) for the container's own log (which is dockerd's output), and `command: ["--log-opt", "max-size=10m", "--log-opt", "max-file=5"]`, the inner daemon's default for its containers. Those flags clash with an `/etc/docker/daemon.json` carrying `log-opts` — dockerd refuses an option given both ways — so drop `command:` when mounting one.

## Testing

`tests/smoke.sh IMAGE [CYCLES]` (bash, host side) runs the image on fresh volumes and stops at the first failed check: startup, tini running as subreaper, `DIND_DNS` (a bad entry dropped, the good ones in the inner `resolv.conf`), `DOCKER_DAEMON_INTERNAL_BIP` (`docker0` gateway and an inner container's address on that subnet), an unmarked `.bashrc` moved aside, `HOME` for alpine / `sudo` / `sudo -i` / `exec -u root`, the prompt colours, `(env)` and `(branch)` for alpine and root, an inner `--restart unless-stopped` workload, a second container on the same volumes refused with 75 while the first stays untouched, the command path next to the daemon, `docker stop`, `CYCLES` `docker kill`/`docker start` rounds, a double SIGTERM, and a SIGKILLed dockerd exiting non-zero and coming back. With PM2 present it also checks the full variant: venv on the login-shell PATH and writable, `pm2-logrotate` not restarted by the boot. The inner workload image is `docker import`ed from the dind container's own busybox and musl loader, so no registry is needed; everything is named `dind-smoke-<pid>-*` and removed on exit. CI runs it against every release digest before tagging.

Its log checks count over `docker logs`, which spans every boot of the container, so they compare deltas. A graceful stop must add exactly one `Processing signal 'terminated'` and one `Daemon shutdown complete`.

Not covered there, check by hand when touching it: the interactive path, e.g. `script -qec "docker run --rm -it --privileged IMAGE"`. dockerd's output must go to `/var/log/dockerd.log`, not the terminal, and `exit` must stop the daemon cleanly.

## Architecture

### Privilege inversion in the entrypoints

The image ends with `USER alpine` (uid/gid 1000) but `dockerd` must run as root. `entrypoint.sh` / `entrypoint.minimal.sh` resolve this by running as `alpine` and escalating through passwordless sudo. `/etc/sudoers.d/alpine` sets `!env_reset`, so the environment (`DOCKER_TLS_CERTDIR`, `TINI_SUBREAPER`, …) reaches `dockerd-entrypoint.sh`, and `always_set_home`, because with the environment kept root would otherwise inherit `HOME=/home/alpine` and write its dotfiles and caches there. The build validates it with `visudo -c`. `as_root()` is the escalation helper; it no-ops when already uid 0, so the same script works if someone overrides `user: root`.

sudo closes inherited descriptors above 2, so whatever must hold one across the escalation (the data-root lock) has to run on the root side. That is the internal re-entry: the daemon paths run `as_root "$0" __dind_env_dockerd LOG ARGS…`, and a script started with that first argument only runs `exec_dockerd_locked()` (lock, optional log redirect, `exec dockerd-entrypoint.sh`). It is dispatched before `prepare_home`, so nothing else runs twice.

Argument dispatch at the bottom of both scripts:

- no args, or first arg starts with `-` → the daemon path: the re-entry in the background, wait until the API answers on `/var/run/docker.sock` (90 × 0.5s; the socket alone appears before the daemon finishes initialising), fix socket group/mode, then a login shell as a child (TTY present) or `supervise()`. This is the normal compose path.
- first arg `dockerd` → `exec` the re-entry (lock included), no background daemon.
- anything else → run it as `alpine` via upstream `docker-entrypoint.sh`.

Both daemon paths refuse (exit 75) while a `dockerd` or `containerd` already runs in the container. The PID namespace is empty at container start, so that only happens when the script is re-run through `docker exec` — which used to strip the live daemon's pidfile and socket. They then turn `DIND_DNS` (space- or comma-separated) into one `--dns=` per entry; entries that are not IP addresses are dropped with a warning, because dockerd refuses to start on them and a typo must not keep it down after the next reboot. `DOCKER_DAEMON_INTERNAL_BIP` becomes `--bip` the same way: `normalize_bip()` accepts an IPv4 CIDR with prefix 8–29, turns a network address into its first host (`10.10.100.0/24` → `10.10.100.1/24`, which dockerd would otherwise take as the bridge IP itself) and drops anything else with a warning; an explicit `--bip` argument wins, since dockerd refuses the option twice. It only moves `docker0`: user-defined networks keep dockerd's default address pools.

With a TTY, dockerd's output goes to `/var/log/dockerd.log` instead of the terminal the shell uses, and `supervise()` prints the log's tail if the daemon dies.

### PID 1 must stay the entrypoint script

This path never `exec`s. `supervise()` idles in `wait` and the TTY branch uses `run_as_alpine_child`, because an `exec`d `sleep infinity` or `bash -l` becomes a PID 1 with no SIGTERM handler — and the kernel discards unhandled signals sent to PID 1. Previously `docker stop` therefore hung for its full grace period and SIGKILLed dockerd (measured: 10s, exit 137, no `Daemon shutdown complete` in the log), which is what produced the stale state `cleanup_stale_runtime_state()` cleans. `exec` survives only in `run_as_alpine`, used by the two dispatch paths that run a command instead of supervising a daemon.

This is also why all three compose files set `tty: false` / `stdin_open: false`. With a TTY the entrypoint takes the interactive branch, and a **foreground** child blocks trap delivery in POSIX `sh` — PID 1 sits in the shell, the pending SIGTERM is never dispatched, and `docker stop` degrades to SIGKILL again (measured: 10s, exit 137, even with PID 1 correct). `docker compose run` allocates its own TTY, so the interactive path stays reachable there; exiting that shell falls through to `shutdown` explicitly. A `docker stop` aimed at an interactive `compose run` container still needs the SIGKILL fallback — acceptable for an ephemeral `--rm` container. The same deferral applies to everything else PID 1 runs in the foreground, which is why every pm2 call in `start_pm2()` is wrapped in `timeout`.

`shutdown()` on INT/TERM first disarms its own trap, stops PM2 (full variant), then `stop_dockerd()` sends dockerd **exactly one** SIGTERM — by pidfile through `as_root`, `killall -TERM dockerd` only when there is no pidfile — and waits up to 90s for it to go. One is a hard limit, not style: dockerd abandons its graceful shutdown on the 4th INT/TERM ("Forcing docker daemon shutdown without cleanup; 3 interrupts received"). `/var/run` is a symlink to `/run`, so the old loop over both pidfiles plus the `pkill` already sent 3, and a second `docker stop` re-entering the handler made it 4 (measured: forced exit after 2s instead of ~12s, inner containers left to the kernel's SIGKILL). The 90s cap sits above `stop_grace_period: 60s` on purpose: on `docker stop` Docker's timeout decides, and the cap only bounds the interactive-exit path. It cannot use `$DOCKERD_PID`: because `as_root` is a shell function, `as_root … &` forks a subshell rather than exec'ing, so `$!` is that helper shell, two levels above dockerd — and it is root-owned, so an unprivileged `kill` returns EPERM. `$DOCKERD_PID` does decide *whether* to signal: once our launch has exited (daemon died, lock refused) the pidfile is not ours to act on.

`wait_docker()` returns 0 once the API answers, or after 45s when the socket exists (up but slow: continue with a warning), and 1 when our launch has exited or never created its socket. Only on 0 do PM2 and the interactive shell start. That gate keeps a container that lost the data-root lock away from the PM2 of the instance it shares a home with.

`supervise()` calls `wait` before looking at `kill -0`: busybox ash reaps background jobs while waiting for any foreground command, so the job may already be gone when supervise starts. `wait` still returns its saved status; a `kill -0` in front would lose it (a lost lock's 75 would read as 1). It returns only when dockerd died on its own, which is a failure: it exits with dockerd's status, or 1 if that was 0 — exiting 0 used to hide a daemon that never came up from `docker ps`, monitoring and `on-failure` restarts.

Anything in the entrypoints that touches `/run/docker.pid`, `/var/run/docker.pid` or `docker.sock` must go through `as_root`. Those live in root-owned dirs, the scripts run as `alpine`, and every such call is `|| true`-guarded — so a missing `as_root` fails silently and the cleanup becomes a no-op.

`fix_runtime()` relaxes `/certs/client` only. Do not widen `/certs` recursively: the upstream dind entrypoint creates `/certs/ca/key.pem` and `/certs/server/key.pem` at `0600` on purpose, and a readable CA key lets anyone mint client certs the daemon trusts.

### Data-root lock

`exec_dockerd_locked()` opens `/var/lib/docker/.dind-env.lock` on fd 9, takes `flock -n -E 75 9` and `exec`s `dockerd-entrypoint.sh` with the fd still open, so dockerd — and through it docker-init, containerd and the shims, though not the inner containers' processes, which runc starts without it — holds the lock for as long as it runs. Two containers on one data-root (`docker compose run --rm dind` next to `up`, a copied project with the same `DOCKER_DATA`, a named volume attached twice) would otherwise run two dockerd on the same `/var/lib/docker` and corrupt it. The second logs `ERROR: another dockerd holds …` and exits 75; with `unless-stopped` it retries on Docker's backoff until the first one stops.

The kernel drops a flock with its last holder, so a hard stop cannot leave it stale; the file itself is harmless. Any failure other than "held" — the file cannot be created, `flock` is missing, or it is busybox's applet, which has no `-E` — logs a warning and starts dockerd without the lock: a broken lock must never keep the daemon down. That is why the image installs util-linux `flock`; only its `-E` tells "held" from everything else.

Everything the loser can reach is shared through the volumes: the lock, the data-root, and the home with PM2's RPC socket in `~/.pm2`. So the PM2 stale-file cleanup lives in `start_pm2()`, after the lock and `wait_docker()`, never in `prepare_home()` or `cleanup_stale_runtime_state()`, and `stop_pm2()` does nothing unless this container started PM2: a `pm2 kill` from the loser would otherwise reach the winner's daemon through that socket and kill its apps.

### Dotfile seeding and the `dind-env-` marker

Dotfiles are baked into `/etc/skel` and into `/home/alpine` at build time, but `/home/alpine` is a volume — with a bind mount to an empty host dir the baked copies are masked. `prepare_home()` re-seeds them at runtime. `seed_dotfile()` leaves a destination alone when it contains the string `dind-env-`; otherwise it moves the existing file (or dangling link) to `<name>.dind-env-backup.<timestamp>` and installs the image's copy. That copy carries the marker, so a user's own file is moved aside once, not overwritten on every start as it used to be.

Consequence: `bashrc`, `bash_aliases`, and `profile` each carry a `# dind-env-*` marker comment on line 1–2. Removing it makes the entrypoint move the file aside at the next start. Keep the marker when editing these files.

`prepare_home()` is best effort: a home that root cannot write (read-only mount, NFS with root_squash) must not keep the daemon from starting, so failures there are reported by the tools and ignored.

The `bashrc` prompt is `user@host` (green, red for root) + `(DIND_ENVIRONMENT_NAME)` (yellow, omitted when empty) + `(branch)` (cyan) + `:dir`. `__dind_git_branch` reads `.git/HEAD` itself instead of running `git` or `__git_ps1`: root sits in alpine's checkouts, where git refuses with "dubious ownership", and a prompt running git as root would execute a repository's `core.fsmonitor`. The cost is no dirty/ahead indicators. root's login shell is set to `/bin/bash` in both Dockerfiles (Alpine's default is `/bin/sh`): `sudo su` and `sudo -i` use the passwd shell, and with ash they got no `.bashrc`, so no prompt. `sudo -i` / `su -` also give root a clean environment, so `write_env_name()` in the entrypoints mirrors `DIND_ENVIRONMENT_NAME` into `/etc/dind-environment-name` at each start, and `__dind_env_name` falls back to it. `git` itself is installed in both images.

`bashrc` (interactive non-login shells, e.g. `docker compose exec dind bash`) and `profile` (login shells) both prepend `~/go/bin ~/.cargo/bin ~/bin ~/.local/bin` to `PATH`, skipping entries already present so nested shells do not grow it. Alpine's `/etc/profile` resets `PATH` for login shells; the full image's `/etc/profile.d/00dind-path.sh` restores the image `PATH` (venv, JDK) right after. `/etc/profile` is read by ash login shells too (root's `sudo -i`), so `20direnv.sh` hooks direnv into bash only.

### Stale-state cleanup

`cleanup_stale_runtime_state()` exists because the container's writable layer, `/var/lib/docker` and `/home/alpine` persist across container restarts while pidfiles and sockets in them do not correspond to live processes. `/run` in particular is not a tmpfs here, unlike on a real host.

It does nothing while a `dockerd` or `containerd` runs in the container (the script re-run through `docker exec`). Process-name checks use `pidof`, never `pgrep -x`: busybox pgrep matches `argv[0]`, and containerd runs as `/usr/local/bin/containerd`, so `pgrep -x containerd` never finds it. Otherwise nothing that could own the state is alive, so it removes dockerd's exec-root `/var/run/docker` whole, then the pidfiles and sockets under both `/var/run` and `/run`, without reading or signalling any pid: a pid from a stale pidfile names, if anything, an unrelated process in the new namespace.

The exec-root wipe is what decides whether a hard stop (power loss, host crash, OOM kill, `docker kill`) is survivable. Without it `/var/run/docker/containerd/containerd.pid` survives; once that pid is reused by any live process in the new PID namespace, dockerd logs "containerd is still running", waits, and exits with "timeout waiting for containerd to start". Measured with the old script: after `docker kill` + `docker start`, 5 of 6 restarts failed that way (exit 0, ~15s each); with the wipe, 0 of 24 across both variants, inner `unless-stopped` containers back every time. The upstream entrypoint only deletes `docker*.pid`, which does not match `containerd.pid`.

All three compose files set `restart: unless-stopped`, so the host daemon brings the container back at boot and after a crash; it restarts on any exit code, unlike `on-failure`. `docker compose run` drops the policy for its one-off containers, so `run --rm` still works.

### Full vs minimal

Same base, same user/sudo/rclone/fuse/bind-mount logic, same dotfiles. The full variant adds Rust, Go, the C/C++ toolchain (`build-base`), Node/npm, Java 21, a Python venv at `/opt/venv` (prepended to `PATH`, owned by `alpine` so `pip install` needs no sudo), GitHub CLI, and globally-installed `prettier eslint typescript @angular/cli pm2`. `pm2-logrotate` is a PM2 module (`pm2 install`), not an npm global.

Both variants deliberately install `coreutils` and `tar` to displace the busybox applets. Alpine's `tar` package overwrites `/bin/tar` — the busybox symlink — with the real GNU binary, so there is no PATH-order subtlety and no `/usr/bin/tar`. Neither package is redundant: dropping them silently reverts `tar` to busybox 1.37 (no `--sort`, `--xattrs`, `--owner`/`--group`, `--wildcards`) and `ls`/`dircolors`/`date` to the busybox versions. `busybox tar` still works if the applet is ever needed explicitly. Likewise `flock` (util-linux, for the data-root lock) and `ncurses` (`tput`, without which the bashrc prompt has no colours).

Both Dockerfiles run `apk upgrade --no-cache` before `apk add`: the pinned `docker:X-dind` base lags the Alpine repositories (measured on 29.8.2: `nghttp2-libs` 1.69.0 vs 1.70.0, `pcre2` 10.48 vs 10.49), so without it the base's own libraries keep their old security fixes until the next upstream tag. Builds are therefore not reproducible day to day, as they already were for the added packages.

`TINI_SUBREAPER=1`: `docker-init` (tini) runs below our PID 1, and without subreaper status it warns that it cannot reap dockerd's orphans. rclone is fetched for `DIND_RCLONE_VERSION` (default `current`, resolved through `version.txt`) and checked against that release's `SHA256SUMS`. The build arg is not called `RCLONE_VERSION` because rclone reads `RCLONE_*` variables as flag defaults and takes that one for `--version`. `user_allow_other` goes into `/etc/fuse.conf`, the file both fuse2 and fuse3 read.

PM2 exists only in the full variant, and only there does the entrypoint call `start_pm2()`: clear the stale sockets/pidfiles in `~/.pm2`, ping, `pm2 resurrect` if `~/.pm2/dump.pm2` or `dump.pm2.bak` is non-empty (resurrect falls back to the `.bak` by itself when the dump is empty or torn after a hard stop), install `pm2-logrotate` if missing, configure it, `pm2 save`. `pm2_conf()` sets an option only when `pm2 get` shows a different value: every `pm2 set` restarts the module, even with the same value. `pm2 get` prints `Value for module <name> key <key>: <value>`; if that format changes the comparison fails and the value is simply set again. Keep the boot-time save: `pm2 save` first copies the current dump to `dump.pm2.bak`, so after one boot the `.bak` holds the same list and is a real fallback; without it the `.bak` is whatever the user's previous save was (often `[]`). The Dockerfile pre-seeds a configured `.pm2` into `/etc/skel/.pm2` (installed, configured, killed, sockets stripped) so a fresh bind-mounted home gets working logrotate settings without a first-run install.

Changes to shared behaviour must be applied to **both** entrypoints and **both** Dockerfiles — they are duplicated, not shared. `entrypoint.minimal.sh` is `entrypoint.sh` minus everything PM2.

### Build context

`.dockerignore` is deny-everything-then-allowlist. Any new file that a Dockerfile `COPY`s must be added to it explicitly or the build fails with "file not found".

### Release pipeline (`.github/workflows/release.yml`)

Tag `vX.Y.Z` triggers:

1. `prepare` — decides whether the tag is the highest `vX.Y.Z` (`sort -V`); only then do the image and the GitHub release get `latest`, so a patch for an older line cannot roll it back. Resolves the rclone version once, so every platform build ships the same one.
2. `lint` — shellcheck on both entrypoints and the smoke test, `docker compose config -q` on the three compose files.
3. `build` — 4 jobs (full/minimal × amd64 on `ubuntu-24.04` / arm64 on `ubuntu-24.04-arm`, native runners, no QEMU), `no-cache` and `pull` on purpose: with a layer cache the `apk add` layer never changes until the Dockerfile does, and releases would keep shipping the same packages without their security fixes. Each pushes by digest only (`push-by-digest=true`, no tag) and uploads the digest as an artifact.
4. `smoke` — per variant × arch, pulls that digest on its native runner and runs `tests/smoke.sh`.
5. `merge` — needs prepare, lint and smoke. Per variant, `docker buildx imagetools create` assembles the manifest list from the digests and applies `X.Y.Z`, `X.Y`, `vX.Y.Z` and, for the highest release only, `latest` (`flavor: latest=false`, or metadata-action adds it to every semver tag by itself). A failed check leaves only untagged digests behind.
6. `release` — rewrites all three compose files with an inline Python script that **pins `image:` to the released version** (and would strip a `build:` block, should one come back: the compose files have none today, since the build context is not part of the download), then attaches them to the GitHub Release, `make_latest` as decided by prepare.

That stamping script is indentation-sensitive: it rewrites any line starting with `    image:` and, as a guard, drops a `    build:` (4 spaces) block with its deeper-indented lines. It asserts no `build:` is left and the pinned `image:` is there, so re-indenting the `dind` service in a compose file now fails the release instead of silently breaking its assets.

Top-level permissions are `contents: read`; jobs raise what they need (`packages: write` for build and merge, `packages: read` for smoke, `contents: write` for release). Actions are pinned by commit SHA with the version in a comment, and `.github/dependabot.yml` proposes updates for them and for the base image weekly.

Repo name is interpolated into the image name and lowercased in CI, so the image path follows `github.repository` — not a hardcoded value.

## Incus variant (branch `incus`)

`Dockerfile.incus`, `entrypoint.incus.sh`, `docker-compose.incus.yml`, `tests/smoke.incus.sh`; documented in `README_INCUS.md` (Italian, with the test matrix). Incus 7.5.1 instead of Docker: `incusd` is built from the release tarball (Alpine only ships the 7.0.1 LTS), the official web UI (`zabbly/incus-ui-canonical`, needs a git checkout and the removal of `src/types/parse-prometheus-text-format.d.ts`) is served by `incusd` from `INCUS_UI`. Not in the release pipeline yet. Lint/smoke: `shellcheck entrypoint.incus.sh tests/smoke.incus.sh`, `just smoke-incus TAG`.

- **PID 1 is tini**, the entrypoint its only child (`ENTRYPOINT ["/sbin/tini","--",…]`), so unlike the Docker entrypoints it does not need to stay PID 1 itself. It still never `exec`s in the daemon path and keeps the INT/TERM trap.
- **Not privileged**: `cap_add: ALL`, `apparmor`/`seccomp`/`systempaths=unconfined`, `cgroup: private`, `/dev/fuse` (lxcfs), loop-control and tun, plus `device_cgroup_rules`. `/sys` and `/sys/fs/cgroup` are remounted rw by the root side.
- **cgroups (`setup_cgroups`)**: LXC takes the base cgroup from `/proc/1/cgroup`, strips `init.scope` and writes `+controller` to its `cgroup.subtree_control`; a cgroup holding processes cannot enable controllers (EBUSY). So every process moves to `/sys/fs/cgroup/init.scope` and all controllers are enabled at the root, retried because `wait_incus` keeps forking unprivileged children into the root cgroup meanwhile. Using `/init` leaves no `memory.max` ("Failed to set memory.max").
- **Stale state is cleaned in two halves.** `/run/incus`, `/run/lxc` and the lxcfs mount belong to the container and go first; the files in the data volume (`unix.socket`, `guestapi/sock`, `networks/*/dnsmasq.pid`, `forkdns.*`) go **after** the `flock`, in the root re-entry. Before the lock, a loser on a shared volume deleted the winner's socket. The glob must run in a root shell (`as_root sh -c`): `/var/lib/incus/networks` is `drwx--x--x`, and an unexpanded pattern removed nothing, which left a `dnsmasq.pid` naming a live pid and the bridge failing to start.
- `wait_incus` requires `pidof incusd` before `incus info`: a loser's client would otherwise be answered by the winner's socket on the shared volume.
- Shutdown is one `incus admin shutdown --timeout N` (instances, then the daemon), SIGTERM to `incusd` only when the API is unreachable.
- `docker kill` marks the container as manually stopped, so `restart: unless-stopped` does not bring it back (neither does `stop`); the crash test is `kill -9` of the container's PID 1 from the host.
- One-time preseed (marker `/var/lib/incus/.incus-env-initialized`); the HTTPS address, the bridge subnet and the trusted client certificate (`INCUS_ENV_*`) follow the environment at every start.
