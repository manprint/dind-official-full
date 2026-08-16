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
	if [ ! -d /home/alpine/.pm2/modules/pm2-logrotate ] && [ -d /etc/skel/.pm2 ]; then
		as_root mkdir -p /home/alpine/.pm2
		as_root cp -a /etc/skel/.pm2/. /home/alpine/.pm2/
		as_root rm -f /home/alpine/.pm2/*.sock /home/alpine/.pm2/pm2.pid
		as_root chown -R alpine:alpine /home/alpine/.pm2
	fi
}

pm2_as_alpine() {
	if [ "$UID_NOW" = "0" ]; then
		sudo -u alpine -H -- "$@"
	else
		"$@"
	fi
}

start_pm2() {
	pm2_as_alpine pm2 ping >/dev/null 2>&1 || true
	if [ -s /home/alpine/.pm2/dump.pm2 ]; then
		pm2_as_alpine pm2 resurrect >/dev/null 2>&1 || true
	fi
	if ! pm2_as_alpine pm2 describe pm2-logrotate >/dev/null 2>&1; then
		pm2_as_alpine pm2 install pm2-logrotate >/dev/null 2>&1 || true
	fi
	pm2_as_alpine pm2 set pm2-logrotate:max_size 10M >/dev/null 2>&1 || true
	pm2_as_alpine pm2 set pm2-logrotate:retain 7 >/dev/null 2>&1 || true
	pm2_as_alpine pm2 set pm2-logrotate:compress true >/dev/null 2>&1 || true
	pm2_as_alpine pm2 save >/dev/null 2>&1 || true
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

if [ "$#" -eq 0 ] || [ "${1#-}" != "$1" ]; then
	trap shutdown INT TERM
	as_root dockerd-entrypoint.sh "$@" &
	DOCKERD_PID=$!
	wait_docker
	start_pm2
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


