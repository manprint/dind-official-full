#!/usr/bin/env bash
# shellcheck disable=SC2016 # single-quoted commands run in the container's shell
#
# Smoke test for the Incus image:
#
#   tests/smoke.incus.sh IMAGE [CYCLES]
#
# Covers startup and preseed, the API and the web UI, an instance with limits
# (memory, cpu) and its capabilities, a second container on the same data directory
# (refused with 75, the first untouched), graceful stop, CYCLES hard kills
# with stale runtime files planted in the data directory, a double SIGTERM and an
# incusd crash. Needs a Docker host that allows --cap-add ALL with
# systempaths=unconfined, cgroup v2 and /dev/fuse; no registry access, the
# instance image is built from the container's own busybox. Everything it
# creates is named incus-smoke-<pid>-* and removed on exit.
set -euo pipefail

IMAGE="${1:?usage: $0 IMAGE [CYCLES]}"
CYCLES="${2:-3}"
ID="incus-smoke-$$"
MAIN="$ID-main"
SECOND="$ID-second"
# Bind mounts, like the compose file; root-owned files from the container are
# removed from inside it.
BASE="$(mktemp -d)"
DATA="$BASE/data"
HOMEV="$BASE/home"

RUN_FLAGS=(
	--cap-add ALL
	--security-opt apparmor=unconfined
	--security-opt seccomp=unconfined
	--security-opt systempaths=unconfined
	--cgroupns private
	--device /dev/fuse
	--stop-timeout 120
	-e DIND_ENVIRONMENT_NAME=smokeenv
	-v "$DATA":/var/lib/incus
	-v "$HOMEV":/home/alpine
)

cleanup() {
	docker rm -f "$MAIN" "$SECOND" >/dev/null 2>&1 || true
	docker run --rm -u 0 --entrypoint sh -v "$BASE":/b "$IMAGE" -c 'rm -rf /b/data /b/home' >/dev/null 2>&1 || true
	rm -rf "$BASE"
}
trap cleanup EXIT

ok() { printf 'ok   - %s\n' "$*"; }

fail() {
	printf 'FAIL - %s\n' "$*" >&2
	docker logs --tail 40 "$MAIN" >&2 2>&1 || true
	exit 1
}

# Occurrences of a fixed string in the main container's log, all boots.
count() { docker logs "$MAIN" 2>&1 | grep -cF -- "$1" || true; }

in_main() { docker exec "$MAIN" "$@"; }

wait_ready() {
	for _ in $(seq 1 150); do
		if in_main incus info >/dev/null 2>&1; then
			return 0
		fi
		if [ "$(docker inspect -f '{{.State.Running}}' "$MAIN")" != true ]; then
			fail "container stopped while starting (exit $(docker inspect -f '{{.State.ExitCode}}' "$MAIN"))"
		fi
		sleep 1
	done
	fail "incus API not answering after 150s"
}

# The configure step (API address, trust) runs after the API answers.
wait_configured() {
	for _ in $(seq 1 60); do
		if [ "$(in_main incus config get core.https_address 2>/dev/null)" = ":8443" ]; then
			return 0
		fi
		sleep 1
	done
	fail "core.https_address was not configured"
}

wait_instance() {
	for _ in $(seq 1 60); do
		if [ "$(in_main incus list smk -c s -f csv 2>/dev/null)" = RUNNING ]; then
			return 0
		fi
		sleep 1
	done
	fail "instance smk is not RUNNING (state: $(in_main incus list smk -c s -f csv 2>&1))"
}

# Same checks after every start: the API, the instance and its memory limit.
check_state() {
	wait_ready
	wait_configured
	wait_instance
	mem="$(in_main incus exec smk -- cat /sys/fs/cgroup/memory.max 2>&1)"
	[ "$mem" = 67108864 ] || fail "$1: smk memory.max is '$mem', expected 67108864"
}

echo "== $IMAGE"
mkdir -p "$DATA" "$HOMEV"
docker run -d --name "$MAIN" "${RUN_FLAGS[@]}" "$IMAGE" >/dev/null
wait_ready
wait_configured
ok "startup, incus answers on the unix socket"

[ "$(in_main incus storage list -f csv -c n)" = default ] || fail "storage pool 'default' missing"
[ "$(in_main incus network list -f csv -c nt | grep -c '^incusbr0,bridge')" = 1 ] || fail "bridge incusbr0 missing"
ok "preseed: storage pool default, bridge incusbr0"

[ "$(docker exec -u 0 "$MAIN" pidof tini | wc -w)" = 1 ] || fail "tini is not running"
[ "$(in_main cat /proc/1/comm)" = tini ] || fail "PID 1 is not tini"
ok "tini is PID 1"

[ "$(in_main sh -c 'echo $HOME')" = /home/alpine ] || fail "HOME for alpine"
[ "$(in_main sudo -i sh -c 'echo $HOME')" = /root ] || fail "HOME for sudo -i"
ok "HOME for alpine and sudo -i"

[ "$(in_main cat /etc/dind-environment-name)" = smokeenv ] || fail "environment name file"
ok "environment name for the prompt"

in_main sh -c 'test "$(cat /sys/fs/cgroup/cgroup.subtree_control)" = "$(cat /sys/fs/cgroup/cgroup.controllers)"' ||
	fail "cgroup controllers not delegated at the root"
in_main sh -c 'test -d /sys/fs/cgroup/init.scope' || fail "init.scope missing"
ok "cgroup v2: processes in init.scope, controllers enabled"

[ "$(in_main curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:8443/ui/)" = 200 ] || fail "web UI not served on /ui/"
in_main curl -sk https://127.0.0.1:8443/1.0 | grep -q '"auth":"untrusted"' || fail "API on 8443 not answering"
ok "API and web UI on 8443 (untrusted without a certificate)"

# A rootfs from the container's own busybox: no registry needed.
in_main sh -c '
	set -e
	d=$(mktemp -d)
	mkdir -p "$d/rootfs/bin" "$d/rootfs/sbin" "$d/rootfs/etc" "$d/rootfs/lib" "$d/rootfs/proc" "$d/rootfs/sys" "$d/rootfs/dev" "$d/rootfs/tmp" "$d/rootfs/root" "$d/rootfs/run" "$d/rootfs/mnt"
	cp /bin/busybox "$d/rootfs/bin/busybox"
	cp /lib/ld-musl-*.so.1 "$d/rootfs/lib/"
	for a in sh cat sleep mount ls grep init id date tr cut true; do ln -s busybox "$d/rootfs/bin/$a"; done
	ln -s ../bin/busybox "$d/rootfs/sbin/init"
	echo "::sysinit:/bin/true" >"$d/rootfs/etc/inittab"
	echo "::respawn:/bin/sleep 3600" >>"$d/rootfs/etc/inittab"
	printf "architecture: %s\ncreation_date: %s\nproperties:\n  description: smoke\n  os: smoke\n" "$(uname -m)" "$(date +%s)" >"$d/metadata.yaml"
	tar -C "$d" -cf /tmp/smoke-image.tar metadata.yaml rootfs
	incus image import /tmp/smoke-image.tar --alias smoke >/dev/null
	rm -rf "$d" /tmp/smoke-image.tar
' || fail "building the instance image"
in_main incus launch smoke smk -c limits.memory=64MiB -c limits.cpu=1 -c boot.autostart=true >/dev/null ||
	fail "launching an instance with limits"
wait_instance
ok "instance launched from a local image"

[ "$(in_main incus exec smk -- cat /sys/fs/cgroup/memory.max)" = 67108864 ] || fail "limits.memory not applied"
[ "$(in_main incus exec smk -- cat /proc/meminfo | grep -m1 MemTotal | tr -s ' ' | cut -d' ' -f2)" = 65536 ] || fail "lxcfs meminfo does not follow limits.memory"
ok "limits.memory enforced (cgroup and lxcfs view)"

# Capabilities of an unprivileged instance: the full set, inside its own userns.
[ "$(in_main incus exec smk -- sh -c 'grep CapEff /proc/self/status | tr -d "\t " | cut -d: -f2')" = 000001ffffffffff ] ||
	fail "unprivileged instance does not hold the full capability set"
in_main incus exec smk -- mount -t tmpfs none /mnt || fail "mount inside the instance"
out="$(in_main incus exec smk -- date -s 2020-01-01 2>&1 || true)"
case "$out" in *"Operation not permitted"*) ;; *) fail "an unprivileged instance must not set the host clock (got: $out)" ;; esac
[ "$(in_main date +%Y)" != 2020 ] || fail "the clock moved"
ok "capabilities: full set inside the instance, host clock untouched"

in_main incus config set smk raw.lxc="lxc.cap.keep = chown dac_override fowner setuid setgid kill" || fail "raw.lxc"
in_main incus restart smk
wait_instance
[ "$(in_main incus exec smk -- sh -c 'grep CapBnd /proc/self/status | tr -d "\t " | cut -d: -f2')" = 00000000000000eb ] ||
	fail "lxc.cap.keep did not shrink the bounding set"
in_main incus config unset smk raw.lxc
in_main incus restart smk
wait_instance
ok "lxc.cap.keep narrows the capability set"

docker run -d --name "$SECOND" "${RUN_FLAGS[@]}" "$IMAGE" >/dev/null
for _ in $(seq 1 60); do
	[ "$(docker inspect -f '{{.State.Running}}' "$SECOND")" = false ] && break
	sleep 1
done
[ "$(docker inspect -f '{{.State.ExitCode}}' "$SECOND")" = 75 ] || fail "second container on the same data directory did not exit 75"
docker logs "$SECOND" 2>&1 | grep -q 'another incusd holds' || fail "second container did not say why"
in_main incus list smk -c s -f csv | grep -q RUNNING || fail "first container lost its instance to the second"
in_main incus info >/dev/null || fail "first container lost its socket to the second"
docker rm -f "$SECOND" >/dev/null
ok "second container on the same data directory refused with 75, the first untouched"

before_stop=$(count 'stopping incus')
start=$(date +%s)
docker stop "$MAIN" >/dev/null
took=$(($(date +%s) - start))
[ "$(docker inspect -f '{{.State.ExitCode}}' "$MAIN")" = 0 ] || fail "docker stop: exit $(docker inspect -f '{{.State.ExitCode}}' "$MAIN")"
[ "$(count 'stopping incus')" = $((before_stop + 1)) ] || fail "docker stop did not go through the graceful path"
[ "$(count 'incus stopped')" = 1 ] || fail "no 'incus stopped' after docker stop"
ok "docker stop: exit 0 in ${took}s, graceful"

docker start "$MAIN" >/dev/null
check_state "after docker stop"
ok "instance back RUNNING after docker stop/start, limits intact"

plant_stale() {
	# A pidfile naming a live pid of the new namespace (1), a plain file where the
	# guest socket goes, and a leftover unix socket: what a power loss leaves.
	docker run --rm -u 0 --entrypoint sh -v "$DATA":/d "$IMAGE" -c '
		sed "s/^pid: .*/pid: 1/" /d/networks/incusbr0/dnsmasq.pid >/d/networks/incusbr0/dnsmasq.pid.new 2>/dev/null &&
			mv /d/networks/incusbr0/dnsmasq.pid.new /d/networks/incusbr0/dnsmasq.pid || printf "name: dnsmasq\npid: 1\n" >/d/networks/incusbr0/dnsmasq.pid
		rm -f /d/guestapi/sock; echo junk >/d/guestapi/sock
		touch /d/unix.socket
	'
}

for i in $(seq 1 "$CYCLES"); do
	docker kill "$MAIN" >/dev/null
	plant_stale
	docker start "$MAIN" >/dev/null
	check_state "kill cycle $i"
	[ "$(in_main pidof dnsmasq | wc -w)" = 1 ] || fail "kill cycle $i: bridge dnsmasq not running"
done
ok "$CYCLES x docker kill with stale files planted: incus and the instance came back"

in_main incus exec smk -- true || fail "instance not usable after the kill cycles"
ok "instance usable after the kill cycles"

in_main sudo killall -KILL incusd
for _ in $(seq 1 30); do
	[ "$(docker inspect -f '{{.State.Running}}' "$MAIN")" = false ] && break
	sleep 1
done
[ "$(docker inspect -f '{{.State.Running}}' "$MAIN")" = false ] || fail "container still running after incusd was killed"
[ "$(docker inspect -f '{{.State.ExitCode}}' "$MAIN")" != 0 ] || fail "dead incusd exited 0"
docker start "$MAIN" >/dev/null
check_state "after an incusd crash"
ok "SIGKILLed incusd: container exits non-zero and comes back"

before_stop=$(count 'stopping incus')
docker kill -s TERM "$MAIN" >/dev/null
docker kill -s TERM "$MAIN" >/dev/null 2>&1 || true
for _ in $(seq 1 120); do
	[ "$(docker inspect -f '{{.State.Running}}' "$MAIN")" = false ] && break
	sleep 1
done
[ "$(docker inspect -f '{{.State.ExitCode}}' "$MAIN")" = 0 ] || fail "double SIGTERM: exit $(docker inspect -f '{{.State.ExitCode}}' "$MAIN")"
[ "$(count 'stopping incus')" = $((before_stop + 1)) ] || fail "double SIGTERM shut incus down more than once"
docker start "$MAIN" >/dev/null
check_state "after a double SIGTERM"
ok "double SIGTERM: one graceful shutdown, exit 0, instance back"

echo "all checks passed"
