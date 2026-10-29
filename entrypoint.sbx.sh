#!/bin/sh
# Entrypoint of the sbx image: Docker Sandboxes (sbx) next to entrypoint.minimal.sh.
# tini is PID 1 and this script its only child. entrypoint.minimal.sh runs
# unchanged as a background child of this script (not exec'd): on INT/TERM the
# sandboxes and the sbx daemon must stop before dockerd, and only a parent that
# outlives the minimal entrypoint can order that. The minimal entrypoint still
# sends dockerd its single SIGTERM.
#
# Session per start (/run is the writable layer, so stale sockets are removed):
#   /dev/kvm group     the device's gid becomes a group alpine belongs to
#   dbus session bus   unix:path=/run/user/1000/bus (DBUS_SESSION_BUS_ADDRESS)
#   gnome-keyring      the Secret Service sbx keeps logins and secrets in,
#                      D-Bus activated by sbx-keyring-daemon, which unlocks it
#                      with SBX_KEYRING_PASS_FILE (again after a crash)
#   sbx daemon         started after dockerd: the upstream dind script moves
#                      every process of the root cgroup when it enables nesting;
#                      the sandboxd.pid of a killed container is removed first
set -eu

UID_NOW="$(id -u)"
SBX_HOME=/home/alpine
RUN_DIR=/run/user/1000
MINIMAL=/usr/local/bin/dev-entrypoint-minimal.sh
KEYRING_PASS_FILE="${SBX_KEYRING_PASS_FILE:-/run/secrets/sbx/keyring_pass}"
FALLBACK_PASS_FILE="$SBX_HOME/.local/share/keyrings/.dind-env-keyring-pass"
SBX_STOP_TIMEOUT="${SBX_STOP_TIMEOUT:-60}"
RUNNING_FILE="$SBX_HOME/.sbx/dind-env-running"
MINIMAL_PID=""

# Every directory sbx, its keyring and the backup scripts keep state in. The
# compose file bind-mounts each one; Docker creates missing sources and the
# mount points inside the home as root, so they are handed to alpine here.
SBX_DIRS=".local/state/sandboxes .cache/sandboxes .config/sandboxes .local/share/sandboxes \
.config/sbx .config/com.docker.sandboxes .sbx .local/share/keyrings"
PRIVATE_DIRS=".local/share/keyrings .config/sbx .config/com.docker.sandboxes"

log() { echo "[sbx-entrypoint] $*"; }

as_root() {
	if [ "$UID_NOW" = "0" ]; then
		"$@"
	else
		sudo -n -- "$@"
	fi
}

# sudo re-reads /etc/group, so the kvm group added at this start applies; -E
# keeps the session bus address (alpine's sudoers already has !env_reset).
as_alpine() {
	sudo -n -u alpine -H -E -- "$@"
}

sbx_daemon_running() {
	pgrep -u 1000 -f 'sbx daemon start' >/dev/null 2>&1
}

prepare_sbx_dirs() {
	for d in .local .local/state .local/share .config .cache $SBX_DIRS; do
		p="$SBX_HOME/$d"
		as_root mkdir -p "$p" 2>/dev/null || continue
		[ "$(stat -c %u "$p" 2>/dev/null)" = 1000 ] || as_root chown alpine:alpine "$p" 2>/dev/null || true
	done
	for d in $PRIVATE_DIRS; do
		as_root chmod 0700 "$SBX_HOME/$d" 2>/dev/null || true
	done
	# Left by a kill or a crash. PIDs restart with the container, so it may
	# name another process by now: `sbx daemon start` then waits 10 s for that
	# one to answer and gives up. No sandboxd runs before this script starts it.
	as_root rm -f "$SBX_HOME/.local/state/sandboxes/sandboxes/sandboxd/sandboxd.pid"
	# The workspace mount: a missing source is created by Docker as root. Only
	# an empty one is handed to alpine; a populated one keeps its owners.
	ws="${SBX_WORKSPACE_PATH:-}"
	if [ -n "$ws" ] && [ -d "$ws" ] && [ "$(stat -c %u "$ws")" = 0 ] && [ -z "$(ls -A "$ws" 2>/dev/null)" ]; then
		as_root chown alpine:alpine "$ws" || true
	fi
}

setup_kvm() {
	if [ ! -c /dev/kvm ]; then
		log "WARNING: no /dev/kvm: sbx cannot start sandboxes (KVM on the host, privileged or devices: [/dev/kvm])" >&2
		return 0
	fi
	gid="$(stat -c %g /dev/kvm)"
	grp="$(getent group "$gid" | cut -d: -f1)"
	if [ -z "$grp" ]; then
		as_root groupadd -g "$gid" kvm 2>/dev/null || as_root groupadd -g "$gid" kvmhost 2>/dev/null || true
		grp="$(getent group "$gid" | cut -d: -f1)"
	fi
	[ -n "$grp" ] || { log "WARNING: no group for /dev/kvm (gid $gid)" >&2; return 0; }
	id -nG alpine | tr ' ' '\n' | grep -qx "$grp" || as_root usermod -aG "$grp" alpine || true
}

# The keyring password comes from SBX_KEYRING_PASS_FILE (compose: a host file
# outside the data directory). Without one, a password is generated next to the
# keyring: the container starts unattended, but the keyring is then no
# protection for a copy of the data directory.
keyring_pass_file() {
	if as_root test -s "$KEYRING_PASS_FILE"; then
		echo "$KEYRING_PASS_FILE"
		return 0
	fi
	if [ ! -s "$FALLBACK_PASS_FILE" ]; then
		log "WARNING: no keyring password in $KEYRING_PASS_FILE, generating $FALLBACK_PASS_FILE (stored next to the keyring)" >&2
		(umask 077 && openssl rand -base64 32 | tr -d '\n' >"$FALLBACK_PASS_FILE")
	fi
	echo "$FALLBACK_PASS_FILE"
}

start_session() {
	as_root mkdir -p "$RUN_DIR"
	as_root chown alpine:alpine "$RUN_DIR"
	as_root chmod 0700 "$RUN_DIR"
	as_root rm -rf "$RUN_DIR/bus" "$RUN_DIR/keyring" 2>/dev/null || true
	if ! as_alpine dbus-daemon --session --address="$DBUS_SESSION_BUS_ADDRESS" --fork --nopidfile >/dev/null; then
		log "WARNING: session bus not started: sbx cannot reach the keyring" >&2
		return 1
	fi
	keyring_pass_file >/dev/null
	# The first request starts gnome-keyring through D-Bus activation, unlocked
	# by sbx-keyring-daemon (also after a crash of the daemon).
	if as_alpine python3 -I -c 'import sys, secretstorage
sys.exit(secretstorage.get_default_collection(secretstorage.dbus_init()).is_locked())' 2>/dev/null; then
		log "keyring unlocked"
	else
		log "WARNING: keyring locked (password changed?): sbx login and secrets will fail" >&2
	fi
}

# 0 once dockerd answers; 1 when the minimal entrypoint is gone or 60s passed.
wait_dockerd() {
	deadline=$(($(date +%s) + 60))
	while [ "$(date +%s)" -lt "$deadline" ]; do
		kill -0 "$MINIMAL_PID" 2>/dev/null || return 1
		timeout 5 docker version >/dev/null 2>&1 && return 0
		sleep 1
	done
	return 1
}

start_sbx() {
	if sbx_daemon_running; then
		log "sbx daemon already running"
	elif as_alpine sbx daemon start --detach >/dev/null 2>&1; then
		log "sbx daemon started"
	else
		log "WARNING: sbx daemon not started, see ~/.local/state/sandboxes/sandboxes/sandboxd/daemon.log" >&2
		return 0
	fi
	# SBX_AUTOSTART: "previous" (the sandboxes running at the last clean stop),
	# a list of names (space- or comma-separated), or empty/none.
	case "${SBX_AUTOSTART:-}" in
	"" | none) return 0 ;;
	previous) names="$(cat "$RUNNING_FILE" 2>/dev/null || true)" ;;
	*) names="$(printf '%s' "$SBX_AUTOSTART" | tr ',' ' ')" ;;
	esac
	for name in $names; do
		if as_alpine sbx run -d --name "$name" >/dev/null 2>&1; then
			log "sandbox $name started"
		else
			log "WARNING: sandbox $name not started" >&2
		fi
	done
}

# Bounded by SBX_STOP_TIMEOUT so dockerd keeps time to stop within
# stop_grace_period. The running list is kept for SBX_AUTOSTART=previous.
stop_sbx() {
	sbx_daemon_running || return 0
	# Retried: right after a gnome-keyring crash the daemon answers 503 until
	# D-Bus has started the keyring again.
	tries=0
	until list="$(timeout 15 sbx ls --json 2>/dev/null)"; do
		tries=$((tries + 1))
		[ "$tries" -lt 3 ] || { log "WARNING: sbx ls failed, sandboxes stop with the daemon" >&2; list=""; break; }
		sleep 2
	done
	running="$(printf '%s' "$list" | jq -r '.[] | select(.status == "running") | .name' 2>/dev/null || true)"
	# Kept from the previous stop when the list is unknown.
	[ -z "$list" ] || printf '%s\n' "$running" >"$RUNNING_FILE" 2>/dev/null || true
	if [ -n "$running" ]; then
		log "stopping sandboxes: $(printf '%s' "$running" | tr '\n' ' ')"
		# shellcheck disable=SC2086 # one argument per sandbox
		timeout "$SBX_STOP_TIMEOUT" sbx stop $running >/dev/null 2>&1 || log "WARNING: sandboxes not stopped in ${SBX_STOP_TIMEOUT}s" >&2
	fi
	timeout 30 sbx daemon stop >/dev/null 2>&1 || log "WARNING: sbx daemon stop failed" >&2
	log "sbx stopped"
}

# The trap is disarmed first: a second `docker stop` must not reach the minimal
# entrypoint twice (its dockerd gets exactly one SIGTERM).
# shellcheck disable=SC2317 # only called from the trap
shutdown() {
	trap '' INT TERM
	stop_sbx
	if [ -n "$MINIMAL_PID" ] && kill -0 "$MINIMAL_PID" 2>/dev/null; then
		kill -TERM "$MINIMAL_PID" 2>/dev/null || true
		rc=0
		while kill -0 "$MINIMAL_PID" 2>/dev/null; do
			wait "$MINIMAL_PID" 2>/dev/null && rc=0 || rc=$?
		done
		exit "$rc"
	fi
	exit "${1:-0}"
}

# Not the daemon path (a command, or `dockerd` itself): nothing of sbx starts.
if [ "$#" -gt 0 ] && [ "${1#-}" = "$1" ]; then
	exec "$MINIMAL" "$@"
fi

prepare_sbx_dirs
setup_kvm
trap shutdown INT TERM

# An asynchronous list gets /dev/null as stdin unless redirected: the minimal
# entrypoint must see the terminal of `compose run` to open its shell there.
exec 3<&0
"$MINIMAL" "$@" <&3 &
MINIMAL_PID=$!

start_session || true
if wait_dockerd; then
	start_sbx
else
	log "WARNING: Docker daemon not ready, starting sbx anyway" >&2
	kill -0 "$MINIMAL_PID" 2>/dev/null && start_sbx
fi

while :; do
	wait "$MINIMAL_PID" 2>/dev/null && rc=0 || rc=$?
	kill -0 "$MINIMAL_PID" 2>/dev/null || break
done
log "dind entrypoint exited (status $rc)" >&2
stop_sbx
exit "$rc"
