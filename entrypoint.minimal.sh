#!/bin/sh
set -eu

UID_NOW="$(id -u)"
DOCKERD_PID=""

as_root() {
	if [ "$UID_NOW" = "0" ]; then
		"$@"
	else
		sudo -n -- "$@"
	fi
}

seed_dotfile() {
	src="$1"
	dst="$2"
	if [ ! -e "$dst" ] || ! grep -q 'dind-env-' "$dst" 2>/dev/null; then
		as_root install -m 0644 "$src" "$dst"
	fi
}

prepare_home() {
	as_root mkdir -p /home/alpine
	seed_dotfile /etc/skel/.bashrc /home/alpine/.bashrc
	seed_dotfile /etc/skel/.bash_aliases /home/alpine/.bash_aliases
	seed_dotfile /etc/skel/.profile /home/alpine/.profile
	if [ ! -e /home/alpine/.bash_profile ]; then
		as_root ln -sfn .profile /home/alpine/.bash_profile
	fi
	as_root chown -h alpine:alpine \
		/home/alpine \
		/home/alpine/.bashrc \
		/home/alpine/.bash_aliases \
		/home/alpine/.profile \
		/home/alpine/.bash_profile 2>/dev/null || true
}

cleanup_stale_runtime_state() {
	echo "[dind-entrypoint] cleaning stale Docker runtime state"
	for pidfile in /var/run/docker.pid /run/docker.pid; do
		if [ -f "$pidfile" ]; then
			pid="$(cat "$pidfile" 2>/dev/null || true)"
			if [ -n "${pid:-}" ] && [ "${pid}" != "0" ] && kill -0 "$pid" 2>/dev/null; then
				echo "[dind-entrypoint] stopping stale docker pid ${pid} from $pidfile"
				as_root kill -TERM "$pid" 2>/dev/null || true
				sleep 1
				as_root kill -KILL "$pid" 2>/dev/null || true
			fi
			as_root rm -f "$pidfile" 2>/dev/null || true
		fi
	done

	for sock in /var/run/docker.sock /run/docker.sock; do
		if [ -S "$sock" ]; then
			echo "[dind-entrypoint] removing stale docker socket $sock"
			pidfile=""
			for candidate in /var/run/docker.pid /run/docker.pid; do
				if [ -f "$candidate" ]; then
					pidfile="$candidate"
					break
				fi
			done
			if [ -n "$pidfile" ]; then
				pid="$(cat "$pidfile" 2>/dev/null || true)"
				if [ -n "${pid:-}" ] && [ "${pid}" != "0" ] && kill -0 "$pid" 2>/dev/null; then
					continue
				fi
			fi
			as_root rm -f "$sock" 2>/dev/null || true
		fi
	done
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

wait_docker() {
	i=0
	while [ "$i" -lt 90 ]; do
		if [ -S /var/run/docker.sock ]; then
			fix_runtime
			return 0
		fi
		i=$((i + 1))
		sleep 0.5
	done
	fix_runtime
	return 0
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
shutdown() {
	echo "[dind-entrypoint] stopping Docker daemon"
	for pidfile in /run/docker.pid /var/run/docker.pid; do
		[ -f "$pidfile" ] || continue
		pid="$(cat "$pidfile" 2>/dev/null || true)"
		if [ -n "${pid:-}" ] && [ "${pid}" != "0" ]; then
			as_root kill -TERM "$pid" 2>/dev/null || true
		fi
	done
	as_root pkill -x dockerd 2>/dev/null || true
	i=0
	while [ "$i" -lt 60 ] && pgrep -x dockerd >/dev/null 2>&1; do
		i=$((i + 1))
		sleep 0.5
	done
	echo "[dind-entrypoint] Docker daemon stopped"
	exit 0
}

# PID 1 must keep running this script. An exec'd sleep/bash installs no SIGTERM
# handler, and the kernel discards unhandled signals sent to PID 1, so the trap
# above would never fire: `docker stop` would hang for its grace period and
# then SIGKILL dockerd, which is what leaves the stale state cleaned up above.
supervise() {
	while kill -0 "$DOCKERD_PID" 2>/dev/null; do
		wait "$DOCKERD_PID" 2>/dev/null || true
	done
	echo "[dind-entrypoint] Docker daemon exited"
	shutdown
}

prepare_home
cleanup_stale_runtime_state

if [ "$#" -eq 0 ] || [ "${1#-}" != "$1" ]; then
	trap shutdown INT TERM
	echo "[dind-entrypoint] launching Docker daemon"
	as_root dockerd-entrypoint.sh "$@" &
	DOCKERD_PID=$!
	wait_docker
	echo "[dind-entrypoint] Docker daemon ready on /var/run/docker.sock"
	if [ -t 0 ]; then
		run_as_alpine_child /bin/bash -l || true
		shutdown
	fi
	supervise
fi

if [ "${1:-}" = "dockerd" ]; then
	if [ "$UID_NOW" = "0" ]; then
		exec dockerd-entrypoint.sh "$@"
	fi
	exec sudo -n -- dockerd-entrypoint.sh "$@"
fi

run_as_alpine docker-entrypoint.sh "$@"
