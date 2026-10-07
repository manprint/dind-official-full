#!/usr/bin/env bash
# shellcheck disable=SC2016 # single-quoted commands run in the container's shell
#
# Smoke test for the Incus image:
#
#   tests/smoke.incus.sh IMAGE [CYCLES]
#
# Covers startup and preseed, the API and the web UI, an instance with limits
# (memory, cpu) and its capabilities, a second container on the same data directory
# (refused with 75, the first untouched), graceful stop (the instance shut down in
# order, also while an operation that cannot be cancelled runs and when the API
# does not answer), CYCLES hard kills with stale runtime files planted in the data
# directory, lxcfs and the web UI proxy dying, a server certificate cut short, an
# incusd crash, a double SIGTERM and a crash of the whole container brought back
# by the restart policy. Needs a Docker host that allows --cap-add ALL with
# systempaths=unconfined, cgroup v2, /dev/fuse and --privileged (the crash is a
# SIGKILL sent to the container's PID 1 from the host PID namespace); no
# registry access, the instance image is built from the container's own
# busybox. Everything it creates is named incus-smoke-<pid>-* and removed on exit.
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

# Written by the instance's init when it gets SIGPWR, the signal incus halts
# it with, after a pause that the SIGKILL of a teardown would not leave:
# present only when the instance was shut down in order. Removed at boot.
marker() {
	docker run --rm -u 0 --entrypoint sh -v "$DATA":/d "$IMAGE" \
		-c "cat /d/storage-pools/default/containers/$1/rootfs/root/clean-shutdown 2>/dev/null" || true
}

# docker stop must leave exit 0, within the grace period, with smk shut down in order.
stop_in_order() {
	start=$(date +%s)
	docker stop "$MAIN" >/dev/null
	took=$(($(date +%s) - start))
	[ "$(docker inspect -f '{{.State.ExitCode}}' "$MAIN")" = 0 ] || fail "$1: docker stop exit $(docker inspect -f '{{.State.ExitCode}}' "$MAIN")"
	[ "$took" -lt 60 ] || fail "$1: docker stop took ${took}s"
	[ -n "$(marker smk)" ] || fail "$1: instance smk was not shut down in order"
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

# The proxy on 8080 holds a generated, trusted certificate: no browser setup.
[ "$(in_main curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ui/)" = 200 ] || fail "web UI proxy not serving /ui/ on 8080"
in_main curl -s http://127.0.0.1:8080/1.0 | grep -q '"auth":"trusted"' || fail "web UI proxy is not a trusted client"
[ "$(in_main curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/1.0/instances)" = 200 ] || fail "web UI proxy cannot list instances"
[ "$(in_main sh -c 'incus config trust list --format csv | grep -c incus-ui')" = 1 ] || fail "incus-ui certificate not trusted exactly once"
ok "web UI on 8080 without a browser certificate (proxy trusted as incus-ui)"

[ "$(count 'could not open error log file')" = 0 ] || fail "nginx complains about its error log"
ok "web UI proxy starts without alerts"

# The instance's init, like systemd, does not stop on SIGTERM and halts on
# SIGPWR (see marker). With /root/stubborn it ignores SIGPWR as well.
docker exec -i "$MAIN" sh -c 'cat >/tmp/smoke-init' <<'INIT'
#!/bin/sh
rm -f /root/clean-shutdown
trap '' TERM INT HUP
trap 'if [ ! -e /root/stubborn ]; then sleep 1; date +%s >/root/clean-shutdown; exit 0; fi' PWR
while :; do sleep 1; done
INIT

# A rootfs from the container's own busybox: no registry needed.
in_main sh -c '
	set -e
	d=$(mktemp -d)
	mkdir -p "$d/rootfs/bin" "$d/rootfs/sbin" "$d/rootfs/etc" "$d/rootfs/lib" "$d/rootfs/proc" "$d/rootfs/sys" "$d/rootfs/dev" "$d/rootfs/tmp" "$d/rootfs/root" "$d/rootfs/run" "$d/rootfs/mnt"
	cp /bin/busybox "$d/rootfs/bin/busybox"
	cp /lib/ld-musl-*.so.1 "$d/rootfs/lib/"
	for a in sh cat sleep mount ls grep id date tr cut true rm touch; do ln -s busybox "$d/rootfs/bin/$a"; done
	install -m 0755 /tmp/smoke-init "$d/rootfs/sbin/init"
	rm -f /tmp/smoke-init
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
stop_in_order "docker stop"
[ "$(count 'stopping incus')" = $((before_stop + 1)) ] || fail "docker stop did not go through the graceful path"
[ "$(count 'incus stopped')" = 1 ] || fail "no 'incus stopped' after docker stop"
ok "docker stop: exit 0 in ${took}s, instance shut down in order"

docker start "$MAIN" >/dev/null
check_state "after docker stop"
ok "instance back RUNNING after docker stop/start, limits intact"

# An operation incus cannot cancel (a stop the instance ignores; an export or an
# image download alike) held the shutdown of every instance back for up to
# core.shutdown_timeout, 5 minutes: Docker SIGKILLed them all first.
in_main incus launch smoke slow -c boot.host_shutdown_timeout=5 >/dev/null || fail "launching a second instance"
in_main incus exec slow -- touch /root/stubborn || fail "marking slow as stubborn"
docker exec -d "$MAIN" incus stop slow --timeout 300
for _ in $(seq 1 30); do
	in_main incus operation list -f csv 2>/dev/null | grep 'Stopping instance' | grep -q RUNNING && break
	sleep 1
done
in_main incus operation list -f csv | grep 'Stopping instance' | grep -q RUNNING || fail "no running stop operation"
stop_in_order "docker stop during an operation"
docker start "$MAIN" >/dev/null
check_state "after a stop during an operation"
in_main incus delete -f slow >/dev/null || fail "deleting slow"
ok "docker stop while an operation that cannot be cancelled runs: ${took}s, instance shut down in order"

# The client cannot reach the API (socket 0600, root only): SIGPWR asks incusd
# for the same shutdown. SIGTERM was a reload: the instances kept running, the
# stop waited on their LXC monitors and Docker SIGKILLed everything.
docker exec -u 0 "$MAIN" chmod 600 /var/lib/incus/unix.socket
before_pwr=$(count 'sending SIGPWR')
stop_in_order "docker stop with the API out of reach"
[ "$(count 'sending SIGPWR')" = $((before_pwr + 1)) ] || fail "docker stop with the API out of reach: no SIGPWR fallback"
docker start "$MAIN" >/dev/null
check_state "after a stop with the API out of reach"
ok "docker stop with the API out of reach: SIGPWR, ${took}s, instance shut down in order"

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

# lxcfs serves the instances' /proc views: restarted when it dies, and an
# instance restart picks it up again.
old="$(in_main pidof lxcfs)"
[ "$(in_main cat "/proc/$old/oom_score_adj")" = -1000 ] || fail "lxcfs within the OOM killer's reach"
in_main sudo killall -KILL lxcfs
# A pid other than the old one, not a zombie: pidof lists those too.
lxcfs_back() {
	in_main sh -c 'for p in $(pidof lxcfs); do [ "$p" != "$1" ] && grep -q "^State:[[:space:]]*[^Z[:space:]]" /proc/$p/status && exit 0; done; exit 1' sh "$old"
}
for _ in $(seq 1 30); do
	lxcfs_back && break
	sleep 1
done
lxcfs_back || fail "lxcfs not restarted after it died"
[ "$(in_main sh -c 'cat /proc/$(pidof lxcfs)/oom_score_adj')" = -1000 ] || fail "restarted lxcfs within the OOM killer's reach"
[ "$(count 'lxcfs exited, restarting it')" = 1 ] || fail "lxcfs restart not logged"
in_main incus restart smk || fail "restarting smk after lxcfs died"
wait_instance
[ "$(in_main incus exec smk -- cat /proc/meminfo | grep -m1 MemTotal | tr -s ' ' | cut -d' ' -f2)" = 65536 ] ||
	fail "lxcfs view of limits.memory not back after lxcfs died"
ok "lxcfs out of the OOM killer's reach; killed: restarted, the instance gets its /proc views back at its restart"

# The proxy's master SIGKILLed: its orphaned worker still holds the port. An
# nginx of alpine's that is not the proxy (in a privileged instance, uid 1000
# is alpine's) must outlive the restart.
in_main sh -c 'mkdir -p /tmp/decoy && printf "#!/bin/sh\nwhile :; do sleep 1; done\n" >/tmp/decoy/nginx && chmod +x /tmp/decoy/nginx'
docker exec -d "$MAIN" /tmp/decoy/nginx
sleep 1
in_main pgrep -f /tmp/decoy/nginx >/dev/null || fail "decoy nginx did not start"
in_main sh -c 'kill -KILL "$(cat /tmp/incus-ui/nginx.pid)"'
code=""
for _ in $(seq 1 30); do
	sleep 1
	[ "$(count 'web UI proxy exited, restarting it')" = 1 ] || continue
	code="$(in_main curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ui/ || true)"
	[ "$code" = 200 ] && break
done
[ "$code" = 200 ] || fail "web UI proxy not back after it died (HTTP $code)"
[ "$(in_main sh -c 'cat /proc/$(cat /tmp/incus-ui/nginx.pid)/comm')" = nginx ] || fail "web UI proxy pidfile stale"
in_main pgrep -f /tmp/decoy/nginx >/dev/null || fail "restarting the web UI proxy killed another nginx"
in_main pkill -f /tmp/decoy/nginx || true
ok "web UI proxy killed: restarted, 8080 answers again, other nginx processes untouched"

# incusd loads server.crt/server.key whenever both exist: a pair cut short by a
# power loss during its first start failed every later start.
docker stop "$MAIN" >/dev/null
docker run --rm -u 0 --entrypoint sh -v "$DATA":/d "$IMAGE" -c ': >/d/server.key'
docker start "$MAIN" >/dev/null
check_state "after a server certificate cut short"
[ "$(count 'do not load as a pair')" = 1 ] || fail "torn server certificate not reported"
ok "server certificate cut short: set aside, incusd makes a new one, instance back"

# The daemon only: pidof incusd would also hit the LXC monitors.
in_main sh -c 'sudo kill -KILL "$(cat /run/incus-env.pid)"'
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

# A crash of the whole container (OOM kill, a SIGKILL to PID 1): unlike
# docker kill, which counts as a manual stop, the restart policy brings it back.
docker update --restart unless-stopped "$MAIN" >/dev/null
restarts="$(docker inspect -f '{{.RestartCount}}' "$MAIN")"
pid="$(docker inspect -f '{{.State.Pid}}' "$MAIN")"
docker run --rm --privileged --pid host -u 0 --entrypoint kill "$IMAGE" -KILL "$pid"
back=false
for _ in $(seq 1 60); do
	if [ "$(docker inspect -f '{{.RestartCount}}' "$MAIN")" -gt "$restarts" ] &&
		[ "$(docker inspect -f '{{.State.Running}}' "$MAIN")" = true ]; then
		back=true
		break
	fi
	sleep 1
done
[ "$back" = true ] || fail "restart policy did not bring the container back after its PID 1 was killed"
check_state "after a crash of the container"
docker update --restart no "$MAIN" >/dev/null
ok "PID 1 SIGKILLed from the host: restart policy brings incus and the instance back"

echo "all checks passed"
