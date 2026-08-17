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
				kill -TERM "$pid" 2>/dev/null || true
				sleep 1
				kill -KILL "$pid" 2>/dev/null || true
			fi
			rm -f "$pidfile" 2>/dev/null || true
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
			rm -f "$sock" 2>/dev/null || true
		fi
	done
}

fix_runtime() {
	if [ -S /var/run/docker.sock ]; then
		as_root chgrp docker /var/run/docker.sock 2>/dev/null || true
		as_root chmod 660 /var/run/docker.sock 2>/dev/null || true
	fi
	if [ -d /certs ]; then
		as_root chmod -R a+rX /certs 2>/dev/null || true
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

run_as_alpine() {
	export HOME=/home/alpine
	export USER=alpine
	export LOGNAME=alpine
	export SHELL=/bin/bash
	cd /home/alpine
	if [ "$UID_NOW" = "0" ]; then
		exec sudo -u alpine -H -E -- "$@"
	fi
	exec "$@"
}

shutdown() {
	if [ -n "$DOCKERD_PID" ]; then
		kill "$DOCKERD_PID" 2>/dev/null || true
		wait "$DOCKERD_PID" 2>/dev/null || true
	fi
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
		run_as_alpine /bin/bash -l
	fi
	run_as_alpine sleep infinity
fi

if [ "$1" = "dockerd" ]; then
	if [ "$UID_NOW" = "0" ]; then
		exec dockerd-entrypoint.sh "$@"
	fi
	exec sudo -n -- dockerd-entrypoint.sh "$@"
fi

run_as_alpine docker-entrypoint.sh "$@"