#!/bin/sh
set -eu

UID_NOW="$(id -u)"
DOCKERD_PID=""
DOCKERD_LOG=""
PM2_STARTED=""
DATA_LOCK=/var/lib/docker/.dind-env.lock

as_root() {
	if [ "$UID_NOW" = "0" ]; then
		"$@"
	else
		sudo -n -- "$@"
	fi
}

# A dotfile without the dind-env- marker is the user's own (e.g. a home
# bind-mounted from elsewhere). Set it aside once instead of overwriting it:
# the copy installed in its place carries the marker and is left alone after.
seed_dotfile() {
	src="$1"
	dst="$2"
	if grep -q 'dind-env-' "$dst" 2>/dev/null; then
		return 0
	fi
	if [ -e "$dst" ] || [ -L "$dst" ]; then
		backup="$dst.dind-env-backup.$(date +%Y%m%d%H%M%S)"
		echo "[dind-entrypoint] $dst has no dind-env- marker, moving it to $backup"
		as_root mv -f "$dst" "$backup" || return 0
	fi
	as_root install -m 0644 "$src" "$dst" || true
}

# Best effort throughout: a home root cannot write (read-only bind mount, NFS
# with root_squash) must not keep the daemon from starting.
prepare_home() {
	as_root mkdir -p /home/alpine || true
	seed_dotfile /etc/skel/.bashrc /home/alpine/.bashrc
	seed_dotfile /etc/skel/.bash_aliases /home/alpine/.bash_aliases
	seed_dotfile /etc/skel/.profile /home/alpine/.profile
	if [ ! -e /home/alpine/.bash_profile ]; then
		as_root ln -sfn .profile /home/alpine/.bash_profile || true
	fi
	as_root chown -h alpine:alpine \
		/home/alpine \
		/home/alpine/.bashrc \
		/home/alpine/.bash_aliases \
		/home/alpine/.profile \
		/home/alpine/.bash_profile 2>/dev/null || true
	if [ -d /etc/skel/.pm2 ] && [ ! -d /home/alpine/.pm2 ]; then
		{
			as_root mkdir -p /home/alpine/.pm2 &&
				as_root cp -a /etc/skel/.pm2/. /home/alpine/.pm2/ &&
				as_root chown -R alpine:alpine /home/alpine/.pm2
		} || true
	fi
}

# pidof, not pgrep -x, for every process-name check: busybox pgrep matches
# argv[0], and dockerd starts containerd as /usr/local/bin/containerd, which
# `pgrep -x containerd` never finds. pidof also compares comm and basenames.
daemon_running() {
	pidof dockerd >/dev/null 2>&1 || pidof containerd >/dev/null 2>&1
}

cleanup_stale_runtime_state() {
	# At container start nothing runs yet in this PID namespace, so a daemon
	# here means the script was re-run through `docker exec`: its pidfile,
	# socket and exec-root are live and must stay.
	if daemon_running; then
		echo "[dind-entrypoint] Docker daemon already running, keeping its runtime state"
		return 0
	fi
	echo "[dind-entrypoint] cleaning stale Docker runtime state"
	# /run is not a tmpfs here: it lives in the container's writable layer and
	# survives a hard stop (power loss, host crash, OOM kill, SIGKILL). dockerd's
	# exec-root then keeps a stale containerd.pid, and once that pid is reused
	# by any live process dockerd logs "containerd is still running", waits for
	# it and exits with "timeout waiting for containerd to start": the daemon
	# does not come back. Nothing in there may outlive the daemon, so drop it
	# whole.
	as_root rm -rf /var/run/docker 2>/dev/null || true
	# With no daemon running, any pidfile or socket left is stale. /var/run is
	# a symlink to /run; both spellings are listed in case that changes.
	as_root rm -f /var/run/docker.pid /run/docker.pid \
		/var/run/docker.sock /run/docker.sock 2>/dev/null || true
}

pm2_as_alpine() {
	if [ "$UID_NOW" = "0" ]; then
		sudo -u alpine -H -- "$@"
	else
		"$@"
	fi
}

# Every `pm2 set` restarts the module, so only change what differs. `pm2 get`
# prints "Value for module <name> key <key>: <value>"; should that format
# change, the comparison fails and the value is simply set again.
pm2_conf() {
	current="$(pm2_as_alpine timeout 30 pm2 get "$1" 2>/dev/null || true)"
	if [ "${current##*: }" != "$2" ]; then
		pm2_as_alpine timeout 30 pm2 set "$1" "$2" >/dev/null 2>&1 || true
	fi
}

# Every pm2 call is bounded: this runs in the foreground of PID 1, where a
# pending SIGTERM waits for it, and a hang would also hide a dockerd crash.
start_pm2() {
	echo "[dind-entrypoint] starting PM2"
	# The previous PM2 daemon died with the container, but its RPC sockets and
	# pidfile persist in the home volume. They are cleared only here, once this
	# container owns the data-root: before that the home may be shared with a
	# running instance whose sockets must stay.
	if [ -d /home/alpine/.pm2 ]; then
		as_root rm -f /home/alpine/.pm2/*.sock /home/alpine/.pm2/*.pid 2>/dev/null || true
		as_root chown -R alpine:alpine /home/alpine/.pm2 2>/dev/null || true
	fi
	PM2_STARTED=1
	pm2_as_alpine timeout 30 pm2 ping >/dev/null 2>&1 || true
	# A hard stop can leave dump.pm2 empty or torn; `pm2 resurrect` then falls
	# back to dump.pm2.bak on its own, so gating on dump.pm2 alone would skip it.
	if [ -s /home/alpine/.pm2/dump.pm2 ] || [ -s /home/alpine/.pm2/dump.pm2.bak ]; then
		echo "[dind-entrypoint] resurrecting PM2 dump"
		pm2_as_alpine timeout 60 pm2 resurrect >/dev/null 2>&1 || true
	fi
	if ! pm2_as_alpine timeout 30 pm2 describe pm2-logrotate >/dev/null 2>&1; then
		echo "[dind-entrypoint] installing pm2-logrotate"
		pm2_as_alpine timeout 120 pm2 install pm2-logrotate >/dev/null 2>&1 || true
	fi
	pm2_conf pm2-logrotate:max_size 10M
	pm2_conf pm2-logrotate:retain 7
	pm2_conf pm2-logrotate:compress true
	pm2_as_alpine timeout 30 pm2 save >/dev/null 2>&1 || true
	echo "[dind-entrypoint] PM2 startup complete"
}

# PM2 apps would otherwise be SIGKILLed when PID 1 exits. Stop them first,
# while the Docker daemon they may depend on is still up. Only a PM2 this
# container started: the RPC socket sits in the home volume, and a container
# that lost the data-root lock would otherwise kill the running instance's.
stop_pm2() {
	[ -n "$PM2_STARTED" ] || return 0
	echo "[dind-entrypoint] stopping PM2"
	pm2_as_alpine timeout 30 pm2 kill >/dev/null 2>&1 || true
}

fix_runtime() {
	if [ -S /var/run/docker.sock ]; then
		as_root chgrp docker /var/run/docker.sock 2>/dev/null || true
		as_root chmod 660 /var/run/docker.sock 2>/dev/null || true
	fi
	# Only the client bundle is meant to be readable by non-root; the CA and
	# server private keys stay 0600 as the upstream dind entrypoint created
	# them. A recursive a+rX here would expose the CA key and let any reader
	# mint client certs the daemon trusts.
	if [ -d /certs ]; then
		as_root chmod 0755 /certs 2>/dev/null || true
		if [ -d /certs/client ]; then
			as_root chmod 0755 /certs/client 2>/dev/null || true
			as_root chmod 0644 \
				/certs/client/ca.pem \
				/certs/client/cert.pem \
				/certs/client/key.pem 2>/dev/null || true
		fi
	fi
}

# 0 once the daemon answers, or when it is up but slow to answer; 1 when it
# is gone or never created its socket. Only on 0 may PM2 start.
wait_docker() {
	i=0
	while [ "$i" -lt 90 ]; do
		# Exited, or never got past the data-root lock: nothing to wait for.
		# supervise() reports the status.
		kill -0 "$DOCKERD_PID" 2>/dev/null || return 1
		if [ -S /var/run/docker.sock ]; then
			fix_runtime
			# The socket appears before the daemon has finished initialising
			# (restoring containers after a crash can take a while); only an
			# answered API call means ready.
			if timeout 5 docker -H unix:///var/run/docker.sock version >/dev/null 2>&1; then
				echo "[dind-entrypoint] Docker daemon ready on /var/run/docker.sock"
				return 0
			fi
		fi
		i=$((i + 1))
		sleep 0.5
	done
	if [ -S /var/run/docker.sock ]; then
		fix_runtime
		echo "[dind-entrypoint] WARNING: Docker daemon not answering after 45s, continuing" >&2
		return 0
	fi
	echo "[dind-entrypoint] ERROR: no Docker socket after 45s" >&2
	return 1
}

alpine_env() {
	export HOME=/home/alpine
	export USER=alpine
	export LOGNAME=alpine
	export SHELL=/bin/bash
	cd /home/alpine
}

# Replaces the current process. Only for the dispatch paths that run a command
# instead of supervising a backgrounded daemon.
run_as_alpine() {
	alpine_env
	if [ "$UID_NOW" = "0" ]; then
		exec sudo -u alpine -H -E -- "$@"
	fi
	exec "$@"
}

# Runs as a child, so PID 1 stays this script and keeps its INT/TERM trap.
run_as_alpine_child() {
	alpine_env
	if [ "$UID_NOW" = "0" ]; then
		sudo -u alpine -H -E -- "$@"
	else
		"$@"
	fi
}

# dockerd runs as root behind sudo, so $DOCKERD_PID is only the forked helper
# shell and an unprivileged kill against it fails with EPERM. Signal the daemon
# itself by pidfile, escalating through sudo.
#
# Exactly one SIGTERM: dockerd abandons its graceful shutdown on the 4th
# INT/TERM ("Forcing docker daemon shutdown without cleanup"). /var/run is a
# symlink to /run, so looping over both pidfiles plus a pkill already sent 3,
# and a second `docker stop` re-entering this handler pushed it over.
stop_dockerd() {
	# Our launch is gone (the daemon exited, or never got the data-root lock):
	# whatever the pidfile names now is not ours to stop.
	kill -0 "$DOCKERD_PID" 2>/dev/null || return 0
	echo "[dind-entrypoint] stopping Docker daemon"
	pid="$(cat /var/run/docker.pid 2>/dev/null || true)"
	if [ -n "${pid:-}" ] && [ "${pid}" != "0" ]; then
		as_root kill -TERM "$pid" 2>/dev/null || true
	else
		pid=""
		as_root killall -TERM dockerd 2>/dev/null || true
	fi
	# Capped above stop_grace_period (60s): on `docker stop` Docker's own
	# timeout decides; the cap only bounds the interactive-exit path. Exiting
	# earlier would SIGKILL a daemon still stopping its containers.
	i=0
	while [ "$i" -lt 180 ]; do
		if [ -n "$pid" ]; then
			[ -d "/proc/$pid" ] || break
		else
			pidof dockerd >/dev/null 2>&1 || break
		fi
		i=$((i + 1))
		sleep 0.5
	done
	echo "[dind-entrypoint] Docker daemon stopped"
}

# The trap is disarmed first so that a second `docker stop` cannot re-enter
# and signal dockerd again; SIGKILL still ends a stuck stop.
shutdown() {
	trap '' INT TERM
	stop_pm2
	stop_dockerd
	exit "${1:-0}"
}

# PID 1 must keep running this script. An exec'd sleep/bash installs no SIGTERM
# handler, and the kernel discards unhandled signals sent to PID 1, so the trap
# above would never fire: `docker stop` would hang for its grace period and
# then SIGKILL dockerd, which is what leaves the stale state cleaned up above.
supervise() {
	# wait comes first: it also returns the status of a job the shell already
	# reaped while running a foreground command, where kill -0 would fail and
	# lose it (a lost lock's 75 would read as a plain failure).
	while :; do
		wait "$DOCKERD_PID" 2>/dev/null && rc=0 || rc=$?
		kill -0 "$DOCKERD_PID" 2>/dev/null || break
		sleep 1
	done
	echo "[dind-entrypoint] Docker daemon exited (status $rc)" >&2
	if [ -n "$DOCKERD_LOG" ]; then
		tail -n 20 "$DOCKERD_LOG" >&2 2>/dev/null || true
	fi
	# Nobody asked the container to stop, so this is a failure. Exiting 0 hid
	# a daemon that never came up from `docker ps`, monitoring and on-failure.
	[ "$rc" -ne 0 ] || rc=1
	shutdown "$rc"
}

# dockerd refuses to start on a --dns value that is not an IP address, so
# DIND_DNS entries are checked first: a typo must not keep the daemon down.
is_ip() {
	case "$1" in
	*:*)
		case "$1" in *[!0-9A-Fa-f:.]*) return 1 ;; esac
		;;
	*)
		printf '%s\n' "$1" | awk -F. 'NF != 4 { exit 1 }
			{ for (i = 1; i <= 4; i++) if ($i !~ /^(0|[1-9][0-9]*)$/ || $i + 0 > 255) exit 1 }'
		;;
	esac
}

# Runs as root, in place of dockerd-entrypoint.sh: $1 is a log file (empty:
# the container output), the rest are the dockerd arguments. It takes an
# exclusive flock on the data-root and hands the descriptor down to dockerd,
# so the lock lives exactly as long as the daemon. Two containers on one
# /var/lib/docker (`compose run` next to `up`, a copied project) would
# otherwise run two dockerd on it and corrupt it; the second exits 75 instead.
# The kernel drops the lock with its last holder, so a hard stop cannot leave
# it stale, and any failure other than "held" starts dockerd anyway: a broken
# lock must not keep the daemon down. sudo closes inherited descriptors, which
# is why the lock is taken here and not before escalating.
exec_dockerd_locked() {
	log="$1"
	shift
	if (: >>"$DATA_LOCK") 2>/dev/null; then
		exec 9>>"$DATA_LOCK"
		rc=0
		flock -n -E 75 9 || rc=$?
		if [ "$rc" -eq 75 ]; then
			echo "[dind-entrypoint] ERROR: another dockerd holds $DATA_LOCK: this /var/lib/docker is in use by another container" >&2
			exit 75
		fi
		if [ "$rc" -ne 0 ]; then
			echo "[dind-entrypoint] WARNING: cannot lock $DATA_LOCK (status $rc), starting without the data-root lock" >&2
		fi
	else
		echo "[dind-entrypoint] WARNING: cannot create $DATA_LOCK, starting without the data-root lock" >&2
	fi
	if [ -n "$log" ] && (: >>"$log") 2>/dev/null; then
		exec >>"$log" 2>&1
	fi
	exec dockerd-entrypoint.sh "$@"
}

# Internal re-entry, as root, from the daemon paths below.
if [ "${1:-}" = "__dind_env_dockerd" ]; then
	shift
	exec_dockerd_locked "$@"
fi

prepare_home
cleanup_stale_runtime_state

if [ "$#" -eq 0 ] || [ "${1#-}" != "$1" ] || [ "$1" = "dockerd" ]; then
	if daemon_running; then
		echo "[dind-entrypoint] ERROR: a Docker daemon is already running in this container" >&2
		exit 75
	fi
	# DIND_DNS="10.0.0.2 10.0.0.3" (or comma-separated): resolvers for the
	# inner containers, one --dns each.
	set -f
	for server in $(printf '%s' "${DIND_DNS:-}" | tr ',' ' '); do
		if is_ip "$server"; then
			set -- "$@" "--dns=$server"
		else
			echo "[dind-entrypoint] WARNING: DIND_DNS entry '$server' is not an IP address, ignored" >&2
		fi
	done
	set +f
fi

if [ "$#" -eq 0 ] || [ "${1#-}" != "$1" ]; then
	trap shutdown INT TERM
	# Keep the interactive terminal for the shell.
	if [ -t 0 ]; then
		DOCKERD_LOG=/var/log/dockerd.log
		echo "[dind-entrypoint] interactive session: Docker daemon output goes to $DOCKERD_LOG"
	fi
	echo "[dind-entrypoint] launching Docker daemon"
	as_root "$0" __dind_env_dockerd "$DOCKERD_LOG" "$@" &
	DOCKERD_PID=$!
	if wait_docker; then
		start_pm2
		if [ -t 0 ]; then
			run_as_alpine_child /bin/bash -l || true
			shutdown
		fi
	fi
	supervise
fi

if [ "${1:-}" = "dockerd" ]; then
	if [ "$UID_NOW" = "0" ]; then
		exec_dockerd_locked "" "$@"
	fi
	exec sudo -n -- "$0" __dind_env_dockerd "" "$@"
fi

run_as_alpine docker-entrypoint.sh "$@"
