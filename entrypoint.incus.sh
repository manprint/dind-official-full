#!/bin/sh
# Entrypoint of the Incus image. tini is PID 1 and this script its only child:
# tini reaps every orphan (LXC monitors, dnsmasq, forkproxy…) and forwards
# SIGTERM here, where the trap stops the daemon gracefully.
set -eu

UID_NOW="$(id -u)"
INCUSD_PID=""
INCUSD_LOG=""
DATA_LOCK=/var/lib/incus/.incus-env.lock
INIT_MARKER=/var/lib/incus/.incus-env-initialized
LXCFS_DIR=/var/lib/lxcfs
CGROUP=/sys/fs/cgroup
BRIDGE=incusbr0
# Seconds incus gets to stop the instances on a graceful shutdown. Keep it below
# stop_grace_period: past that Docker SIGKILLs everything, and the instances
# come back as after a crash.
SHUTDOWN_TIMEOUT="${INCUS_ENV_SHUTDOWN_TIMEOUT:-100}"
# Web UI proxy: nginx on UI_PORT, holding a client certificate incus trusts.
UI_PID=""
UI_PORT=8080
UI_CERT_DIR=/home/alpine/.config/incus-ui
UI_RUN_DIR=/tmp/incus-ui

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
		echo "[incus-entrypoint] $dst has no dind-env- marker, moving it to $backup"
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
}

# `sudo -i` and `su -` hand root a clean environment, without
# DIND_ENVIRONMENT_NAME: the prompt falls back to this file.
write_env_name() {
	if [ -n "${DIND_ENVIRONMENT_NAME:-}" ]; then
		printf '%s\n' "$DIND_ENVIRONMENT_NAME" | as_root tee /etc/dind-environment-name >/dev/null 2>&1 || true
	else
		as_root rm -f /etc/dind-environment-name 2>/dev/null || true
	fi
}

# pidof, not pgrep -x: busybox pgrep matches argv[0] only.
daemon_running() {
	pidof incusd >/dev/null 2>&1 || pidof lxcfs >/dev/null 2>&1
}

# /run and /var/lib/incus persist across container restarts (the writable
# layer and the volume), while the processes that owned these files do not. A
# pid read from a stale file names, if anything, an unrelated process of the
# new PID namespace: incus signals the pid in dnsmasq.pid when it restarts the
# bridge, which could be its own daemon. Nothing here is read, only removed.
#
# Two halves, because the data volume can be shared with a container whose
# incusd is alive: only /run (the container's own layer) is cleaned up front;
# the files in /var/lib/incus wait for the data-root lock (see
# cleanup_stale_data_state), or the loser of a lock race would delete the
# winner's sockets.
cleanup_stale_runtime_state() {
	if daemon_running; then
		echo "[incus-entrypoint] incus already running, keeping its runtime state"
		return 0
	fi
	echo "[incus-entrypoint] cleaning stale incus runtime state"
	as_root rm -rf /run/incus /run/lxc 2>/dev/null || true
	# The mount belongs to a mount namespace that is gone, unless the script is
	# re-run inside a live container; the check above covers that.
	as_root umount -l "$LXCFS_DIR" 2>/dev/null || true
}

# Root side, after the lock is ours: nothing else uses these files.
cleanup_stale_data_state() {
	rm -f /var/lib/incus/unix.socket /var/lib/incus/unix.socket.user \
		/var/lib/incus/guestapi/sock \
		/var/lib/incus/networks/*/dnsmasq.pid \
		/var/lib/incus/networks/*/forkdns.server.pid \
		/var/lib/incus/networks/*/forkdns.server.sock 2>/dev/null || true
}

alpine_env() {
	export HOME=/home/alpine
	export USER=alpine
	export LOGNAME=alpine
	export SHELL=/bin/bash
	cd /home/alpine
}

# Replaces the current process. Only for the dispatch path that runs a command
# instead of supervising a backgrounded daemon.
run_as_alpine() {
	alpine_env
	if [ "$UID_NOW" = "0" ]; then
		exec sudo -u alpine -H -E -- "$@"
	fi
	exec "$@"
}

# Runs as a child, so this script keeps its INT/TERM trap.
run_as_alpine_child() {
	alpine_env
	if [ "$UID_NOW" = "0" ]; then
		sudo -u alpine -H -E -- "$@"
	else
		"$@"
	fi
}

# 0 once the API answers, 1 when our launch has exited or never answers.
wait_incus() {
	i=0
	while [ "$i" -lt 240 ]; do
		kill -0 "$INCUSD_PID" 2>/dev/null || return 1
		# incusd of this container, not an answer from the socket of another
		# container on the same volume (whose pid namespace pidof cannot see).
		if pidof incusd >/dev/null 2>&1 && timeout 5 incus info >/dev/null 2>&1; then
			echo "[incus-entrypoint] incus ready on /var/lib/incus/unix.socket"
			return 0
		fi
		i=$((i + 1))
		sleep 0.5
	done
	echo "[incus-entrypoint] ERROR: incus not answering after 120s" >&2
	return 1
}

# Exactly one graceful request: `incus admin shutdown` stops the instances
# (each with its own timeout) and then the daemon. SIGTERM is only the way out
# when the API is unreachable.
stop_incusd() {
	kill -0 "$INCUSD_PID" 2>/dev/null || return 0
	echo "[incus-entrypoint] stopping incus (instances first, up to ${SHUTDOWN_TIMEOUT}s)"
	if ! timeout $((SHUTDOWN_TIMEOUT + 30)) incus admin shutdown --timeout "$SHUTDOWN_TIMEOUT" >/dev/null 2>&1; then
		echo "[incus-entrypoint] graceful shutdown failed, sending SIGTERM" >&2
		as_root killall -TERM incusd 2>/dev/null || true
	fi
	i=0
	while [ "$i" -lt 240 ]; do
		pidof incusd >/dev/null 2>&1 || break
		i=$((i + 1))
		sleep 0.5
	done
	# lxcfs unmounts itself on SIGTERM.
	as_root killall -TERM lxcfs 2>/dev/null || true
	i=0
	while [ "$i" -lt 20 ]; do
		pidof lxcfs >/dev/null 2>&1 || break
		i=$((i + 1))
		sleep 0.5
	done
	echo "[incus-entrypoint] incus stopped"
}

# The trap is disarmed first so that a second `docker stop` cannot re-enter.
shutdown() {
	trap '' INT TERM
	[ -z "$UI_PID" ] || kill -TERM "$UI_PID" 2>/dev/null || true
	stop_incusd
	exit "${1:-0}"
}

supervise() {
	# wait comes first: it also returns the status of a job the shell already
	# reaped while running a foreground command, where kill -0 would fail and
	# lose it (a lost lock's 75 would read as a plain failure).
	while :; do
		wait "$INCUSD_PID" 2>/dev/null && rc=0 || rc=$?
		kill -0 "$INCUSD_PID" 2>/dev/null || break
		sleep 1
	done
	echo "[incus-entrypoint] incus exited (status $rc)" >&2
	if [ -n "$INCUSD_LOG" ]; then
		tail -n 20 "$INCUSD_LOG" >&2 2>/dev/null || true
	fi
	# Nobody asked the container to stop, so this is a failure.
	[ "$rc" -ne 0 ] || rc=1
	shutdown "$rc"
}

# INCUS_ENV_BRIDGE_ADDRESS is an IPv4 CIDR (a.b.c.d/n, n 8-29) for the incus
# bridge. Prints the value to use and fails on anything incus would refuse. A
# network address (10.10.100.0/24, the usual way to write a subnet) is not a
# valid bridge IP: it becomes the first host, 10.10.100.1/24.
normalize_cidr() {
	printf '%s\n' "$1" | awk -F'[./]' '
		NF != 5 { exit 1 }
		{
			for (i = 1; i <= 5; i++) if ($i !~ /^(0|[1-9][0-9]*)$/) exit 1
			for (i = 1; i <= 4; i++) if ($i + 0 > 255) exit 1
			p = $5 + 0
			if (p < 8 || p > 29) exit 1
			ip = (($1 * 256 + $2) * 256 + $3) * 256 + $4
			size = 2 ^ (32 - p)
			host = ip % size
			if (host == size - 1) exit 1
			# Host bits are all zero and at least 3 of them sit in the last octet.
			last = $4 + (host == 0 ? 1 : 0)
			printf "%d.%d.%d.%d/%d\n", $1, $2, $3, last, p
		}'
}

# ---- root side ----------------------------------------------------------

# Incus asks LXC for cgroups, and LXC (root, not relative) builds them next to
# PID 1's cgroup, after enabling the controllers in that cgroup's parent. A
# cgroup that holds processes cannot enable controllers (EBUSY), and every
# process of the container starts in the one cgroup there is. So: move them
# all into init.scope, which LXC strips from PID 1's path as it does under
# systemd, and enable the controllers at the top. Without it, an instance with
# limits.memory or limits.cpu fails to start ("Failed to set memory.max").
setup_cgroups() {
	if [ ! -f "$CGROUP/cgroup.controllers" ]; then
		echo "[incus-entrypoint] WARNING: no cgroup v2 at $CGROUP, instance limits will not work" >&2
		return 0
	fi
	# Not --privileged: Docker mounts /sys and /sys/fs/cgroup read-only.
	# Instances need /sys writable (bridge settings) and the cgroup tree too.
	for m in /sys "$CGROUP"; do
		mount -o remount,rw "$m" 2>/dev/null || true
	done
	[ -w "$CGROUP" ] || echo "[incus-entrypoint] WARNING: $CGROUP is read-only" >&2
	mkdir -p "$CGROUP/init.scope" 2>/dev/null || {
		echo "[incus-entrypoint] WARNING: cannot create $CGROUP/init.scope" >&2
		return 0
	}
	# Processes forked meanwhile by the unprivileged side (wait_incus polls the
	# API) are born in the root cgroup and make the write fail with EBUSY: move
	# everything again until the controllers go through.
	controllers="$(cat "$CGROUP/cgroup.controllers")"
	tries=0
	while :; do
		procs="$(cat "$CGROUP/cgroup.procs" 2>/dev/null || true)"
		for pid in $procs; do
			echo "$pid" >"$CGROUP/init.scope/cgroup.procs" 2>/dev/null || true
		done
		missing=""
		for c in $controllers; do
			echo "+$c" >"$CGROUP/cgroup.subtree_control" 2>/dev/null || missing="$missing $c"
		done
		[ -n "$missing" ] || return 0
		tries=$((tries + 1))
		if [ "$tries" -ge 25 ]; then
			echo "[incus-entrypoint] WARNING: controllers not delegated:$missing; instance limits for them will not work" >&2
			return 0
		fi
		sleep 0.2
	done
}

# File-backed btrfs and lvm pools need loop devices; docker only passes
# /dev/loop-control, the loopN nodes are ours to create (and are lost with the
# container's /dev at every start). Best effort: "dir" pools do not need them.
setup_devices() {
	[ -e /dev/loop-control ] || return 0
	i=0
	while [ "$i" -lt 16 ]; do
		[ -e "/dev/loop$i" ] || mknod "/dev/loop$i" b 7 "$i" 2>/dev/null || break
		i=$((i + 1))
	done
	if [ ! -e /dev/mapper/control ] && [ -w /dev ]; then
		mkdir -p /dev/mapper
		mknod /dev/mapper/control c 10 236 2>/dev/null || true
	fi
}

# The root half of the daemon start, in place of an init system: $1 is a log
# file (empty: the container output), the rest are incusd arguments. It takes
# an exclusive flock on the data directory and hands the descriptor down to
# incusd, so the lock lives exactly as long as the daemon. Two containers on
# one /var/lib/incus (`compose run` next to `up`, a copied project) would
# otherwise run two incusd on the same database; the second exits 75. The
# kernel drops the lock with its last holder, so a hard stop cannot leave it
# stale, and any failure other than "held" starts the daemon anyway.
exec_incusd_locked() {
	log="$1"
	shift
	if (: >>"$DATA_LOCK") 2>/dev/null; then
		exec 9>>"$DATA_LOCK"
		rc=0
		flock -n -E 75 9 || rc=$?
		if [ "$rc" -eq 75 ]; then
			echo "[incus-entrypoint] ERROR: another incusd holds $DATA_LOCK: this /var/lib/incus is in use by another container" >&2
			exit 75
		fi
		if [ "$rc" -ne 0 ]; then
			echo "[incus-entrypoint] WARNING: cannot lock $DATA_LOCK (status $rc), starting without the data directory lock" >&2
		fi
	else
		echo "[incus-entrypoint] WARNING: cannot create $DATA_LOCK, starting without the data directory lock" >&2
	fi
	cleanup_stale_data_state
	if [ -n "$log" ] && (: >>"$log") 2>/dev/null; then
		exec >>"$log" 2>&1
	fi
	setup_cgroups
	setup_devices
	# Unprivileged instances map uids from this range.
	for f in /etc/subuid /etc/subgid; do
		grep -q '^root:' "$f" 2>/dev/null || echo 'root:1000000:1000000000' >>"$f"
	done
	# Instances mount things from the host side: they must propagate.
	mount --make-rshared / 2>/dev/null || echo "[incus-entrypoint] WARNING: cannot make / rshared" >&2
	# lxcfs gives the instances /proc and /sys views that follow their limits.
	# It must not hold the lock: it can outlive a crashed incusd.
	mkdir -p "$LXCFS_DIR" /run/incus
	lxcfs "$LXCFS_DIR" 9>&- &
	i=0
	while [ "$i" -lt 20 ]; do
		grep -q " $LXCFS_DIR fuse" /proc/mounts && break
		i=$((i + 1))
		sleep 0.25
	done
	grep -q " $LXCFS_DIR fuse" /proc/mounts ||
		echo "[incus-entrypoint] WARNING: lxcfs is not mounted (is /dev/fuse passed in?), instances will see the host's /proc" >&2
	exec incusd --group incus-admin "$@"
}

# Internal re-entry, as root, from the daemon paths below.
if [ "${1:-}" = "__incus_env_daemon" ]; then
	shift
	exec_incusd_locked "$@"
fi

# ---- configuration through the API --------------------------------------

# One-time preseed (the marker lives in the data volume), so what the user
# changes afterwards is never put back: storage pool "default" on
# INCUS_ENV_STORAGE_DRIVER, the bridge, and the default profile on both.
preseed_incus() {
	driver="${INCUS_ENV_STORAGE_DRIVER:-dir}"
	bridge_addr="auto"
	if [ -n "${INCUS_ENV_BRIDGE_ADDRESS:-}" ]; then
		if bridge_addr="$(normalize_cidr "$INCUS_ENV_BRIDGE_ADDRESS")"; then
			echo "[incus-entrypoint] bridge $BRIDGE on $bridge_addr (INCUS_ENV_BRIDGE_ADDRESS=$INCUS_ENV_BRIDGE_ADDRESS)"
		else
			echo "[incus-entrypoint] WARNING: INCUS_ENV_BRIDGE_ADDRESS '$INCUS_ENV_BRIDGE_ADDRESS' is not an IPv4 CIDR (a.b.c.d/8-29), using an automatic subnet" >&2
			bridge_addr="auto"
		fi
	fi
	{
		echo "networks:"
		echo "- name: $BRIDGE"
		echo "  type: bridge"
		echo "  config:"
		echo "    ipv4.address: $bridge_addr"
		echo "    ipv4.nat: \"true\""
		echo "    ipv6.address: none"
		echo "storage_pools:"
		echo "- name: default"
		echo "  driver: $driver"
		if [ -n "${INCUS_ENV_STORAGE_SOURCE:-}" ] || [ -n "${INCUS_ENV_STORAGE_SIZE:-}" ]; then
			echo "  config:"
			[ -z "${INCUS_ENV_STORAGE_SOURCE:-}" ] || echo "    source: \"$INCUS_ENV_STORAGE_SOURCE\""
			[ -z "${INCUS_ENV_STORAGE_SIZE:-}" ] || echo "    size: \"$INCUS_ENV_STORAGE_SIZE\""
		fi
		echo "profiles:"
		echo "- name: default"
		echo "  devices:"
		echo "    root:"
		echo "      path: /"
		echo "      pool: default"
		echo "      type: disk"
		echo "    eth0:"
		echo "      name: eth0"
		echo "      network: $BRIDGE"
		echo "      type: nic"
	} >/tmp/incus-preseed.yaml
	if timeout 120 incus admin init --preseed </tmp/incus-preseed.yaml; then
		echo "[incus-entrypoint] preseed applied: storage pool default ($driver), bridge $BRIDGE"
		as_root touch "$INIT_MARKER" || true
	else
		echo "[incus-entrypoint] WARNING: preseed failed (storage driver '$driver'?), it is retried at the next start" >&2
	fi
	rm -f /tmp/incus-preseed.yaml
}

# Each start: the API address, a changed bridge subnet and the trusted client
# certificate follow the environment. Nothing here may keep the daemon down.
configure_incus() {
	if [ ! -e "$INIT_MARKER" ]; then
		preseed_incus
	elif [ -n "${INCUS_ENV_BRIDGE_ADDRESS:-}" ]; then
		if want="$(normalize_cidr "$INCUS_ENV_BRIDGE_ADDRESS")"; then
			have="$(timeout 30 incus network get "$BRIDGE" ipv4.address 2>/dev/null || true)"
			if [ -n "$have" ] && [ "$have" != "$want" ]; then
				echo "[incus-entrypoint] bridge $BRIDGE moves from $have to $want"
				timeout 60 incus network set "$BRIDGE" "ipv4.address=$want" ||
					echo "[incus-entrypoint] WARNING: cannot change the subnet of $BRIDGE" >&2
			fi
		else
			echo "[incus-entrypoint] WARNING: INCUS_ENV_BRIDGE_ADDRESS '$INCUS_ENV_BRIDGE_ADDRESS' is not an IPv4 CIDR (a.b.c.d/8-29), ignored" >&2
		fi
	fi

	# The API (and the web UI under /ui/) listens on INCUS_ENV_HTTPS_ADDRESS;
	# "none" turns it off. Every client needs a trusted certificate or token.
	addr="${INCUS_ENV_HTTPS_ADDRESS:-:8443}"
	case "$addr" in none | off | "") addr="" ;; esac
	have="$(timeout 30 incus config get core.https_address 2>/dev/null || true)"
	if [ "$have" != "$addr" ]; then
		timeout 60 incus config set "core.https_address=$addr" ||
			echo "[incus-entrypoint] WARNING: cannot set core.https_address to '$addr'" >&2
	fi

	# A client certificate to trust without a token, e.g. the one OpenTofu uses.
	if [ -n "${INCUS_ENV_TRUST_CERT_FILE:-}" ]; then
		if [ -r "$INCUS_ENV_TRUST_CERT_FILE" ]; then
			out="$(timeout 30 incus config trust add-certificate "$INCUS_ENV_TRUST_CERT_FILE" --name "${INCUS_ENV_TRUST_CERT_NAME:-trusted-client}" 2>&1)" ||
				case "$out" in
				*"already"*) ;;
				*) echo "[incus-entrypoint] WARNING: cannot trust $INCUS_ENV_TRUST_CERT_FILE: $out" >&2 ;;
				esac
		else
			echo "[incus-entrypoint] WARNING: INCUS_ENV_TRUST_CERT_FILE '$INCUS_ENV_TRUST_CERT_FILE' is not readable" >&2
		fi
	fi
}

# The web UI needs a trusted client certificate in the browser, which means
# generating, downloading, importing and restarting the browser. Instead, nginx
# listens on plain HTTP (UI_PORT) and talks to the API with a certificate this
# script generates once and trusts; the browser needs nothing. Whoever reaches
# the port is an Incus admin, so compose binds it to loopback, and
# INCUS_ENV_UI_PASSWORD adds HTTP basic auth. INCUS_ENV_UI_PROXY=off disables it.
# Nothing here may keep the daemon down.
start_ui_proxy() {
	case "${INCUS_ENV_UI_PROXY:-on}" in off | none | false | no | 0) return 0 ;; esac
	https="${INCUS_ENV_HTTPS_ADDRESS:-:8443}"
	case "$https" in
	none | off | "")
		echo "[incus-entrypoint] web UI proxy skipped: the API is off (INCUS_ENV_HTTPS_ADDRESS=$https)"
		return 0
		;;
	esac
	api_port="${https##*:}"
	case "$api_port" in "" | *[!0-9]*)
		echo "[incus-entrypoint] WARNING: web UI proxy skipped, cannot read a port from INCUS_ENV_HTTPS_ADDRESS '$https'" >&2
		return 0
		;;
	esac
	if ! command -v nginx >/dev/null 2>&1; then
		echo "[incus-entrypoint] WARNING: web UI proxy skipped, nginx is missing" >&2
		return 0
	fi
	if ! mkdir -p "$UI_CERT_DIR" "$UI_RUN_DIR" 2>/dev/null || ! chmod 700 "$UI_CERT_DIR" 2>/dev/null; then
		echo "[incus-entrypoint] WARNING: web UI proxy skipped, cannot write $UI_CERT_DIR" >&2
		return 0
	fi
	crt="$UI_CERT_DIR/client.crt"
	key="$UI_CERT_DIR/client.key"
	if [ ! -s "$crt" ] || [ ! -s "$key" ]; then
		echo "[incus-entrypoint] generating the web UI client certificate in $UI_CERT_DIR"
		rm -f "$crt" "$key"
		if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
			-days 3650 -subj "/CN=incus-ui" -keyout "$key" -out "$crt" >/dev/null 2>&1; then
			echo "[incus-entrypoint] WARNING: web UI proxy skipped, openssl failed" >&2
			rm -f "$crt" "$key"
			return 0
		fi
		chmod 600 "$key"
	fi
	out="$(timeout 30 incus config trust add-certificate "$crt" --name incus-ui 2>&1)" ||
		case "$out" in
		*"already"*) ;;
		*)
			echo "[incus-entrypoint] WARNING: web UI proxy skipped, cannot trust its certificate: $out" >&2
			return 0
			;;
		esac

	auth=""
	if [ -n "${INCUS_ENV_UI_PASSWORD:-}" ]; then
		hash="$(printf '%s' "$INCUS_ENV_UI_PASSWORD" | openssl passwd -apr1 -stdin 2>/dev/null)" || hash=""
		if [ -z "$hash" ]; then
			echo "[incus-entrypoint] WARNING: web UI proxy skipped, cannot hash INCUS_ENV_UI_PASSWORD" >&2
			return 0
		fi
		(umask 077 && printf '%s:%s\n' "${INCUS_ENV_UI_USER:-admin}" "$hash" >"$UI_RUN_DIR/htpasswd")
		auth="auth_basic \"Incus UI\"; auth_basic_user_file $UI_RUN_DIR/htpasswd;"
	fi

	cat >"$UI_RUN_DIR/nginx.conf" <<NGINX
worker_processes 1;
pid $UI_RUN_DIR/nginx.pid;
error_log stderr warn;
events { worker_connections 1024; }
http {
	access_log off;
	client_body_temp_path $UI_RUN_DIR/body;
	proxy_temp_path $UI_RUN_DIR/proxy;
	fastcgi_temp_path $UI_RUN_DIR/fastcgi;
	uwsgi_temp_path $UI_RUN_DIR/uwsgi;
	scgi_temp_path $UI_RUN_DIR/scgi;
	map \$http_upgrade \$connection_upgrade { default upgrade; "" close; }
	server {
		listen $UI_PORT;
		client_max_body_size 0;
		$auth
		absolute_redirect off;
		location = / { return 302 /ui/; }
		location / {
			proxy_pass https://127.0.0.1:$api_port;
			proxy_http_version 1.1;
			proxy_ssl_certificate $crt;
			proxy_ssl_certificate_key $key;
			proxy_ssl_verify off;
			proxy_set_header Host \$http_host;
			proxy_set_header Upgrade \$http_upgrade;
			proxy_set_header Connection \$connection_upgrade;
			proxy_buffering off;
			proxy_request_buffering off;
			proxy_read_timeout 1h;
			proxy_send_timeout 1h;
		}
	}
}
NGINX
	if ! nginx -t -c "$UI_RUN_DIR/nginx.conf" >/dev/null 2>&1; then
		echo "[incus-entrypoint] WARNING: web UI proxy skipped, invalid nginx configuration" >&2
		return 0
	fi
	nginx -c "$UI_RUN_DIR/nginx.conf" -g 'daemon off;' &
	UI_PID=$!
	echo "[incus-entrypoint] web UI on http://HOST:$UI_PORT/ (no browser certificate needed)"
}

prepare_home
write_env_name
cleanup_stale_runtime_state

if [ "$#" -eq 0 ] || [ "${1#-}" != "$1" ] || [ "$1" = "incusd" ]; then
	if daemon_running; then
		echo "[incus-entrypoint] ERROR: incus is already running in this container" >&2
		exit 75
	fi
fi

if [ "$#" -eq 0 ] || [ "${1#-}" != "$1" ]; then
	trap shutdown INT TERM
	# Keep the interactive terminal for the shell.
	if [ -t 0 ]; then
		INCUSD_LOG=/var/log/incusd.log
		echo "[incus-entrypoint] interactive session: incus output goes to $INCUSD_LOG"
	fi
	echo "[incus-entrypoint] launching incus"
	as_root "$0" __incus_env_daemon "$INCUSD_LOG" "$@" &
	INCUSD_PID=$!
	if wait_incus; then
		configure_incus
		start_ui_proxy
		if [ -t 0 ]; then
			run_as_alpine_child /bin/bash -l || true
			shutdown
		fi
	fi
	supervise
fi

if [ "${1:-}" = "incusd" ]; then
	shift
	if [ "$UID_NOW" = "0" ]; then
		exec_incusd_locked "" "$@"
	fi
	exec sudo -n -- "$0" __incus_env_daemon "" "$@"
fi

run_as_alpine "$@"
