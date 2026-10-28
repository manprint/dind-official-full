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
# incusd crash, a double SIGTERM, a crash of the whole container brought back
# by the restart policy, and the startup deadline of an API that never answers. The OpenTofu template of /opt/incus-template/terraform
# too: init from the image's provider mirror, its unit tests, an instance from
# terraform.tfvars and TF_VAR_*, an in-place change, a failed provisioning, a
# second state on the same name, and its state still matching the instance after
# all the stops and crashes. Needs a Docker host that allows --cap-add ALL with
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
ADDR="$ID-addr"
SLOW="$ID-slow"
# docker-compose.incus.yml itself, on its own project, name, ports and network.
CNAME="$ID-compose"
COMPOSE_YML="$(cd "$(dirname "$0")/.." && pwd)/docker-compose.incus.yml"
CAPI=$((20000 + $$ % 20000))
CUI=$((CAPI + 1))
CNET="10.250.$(($$ % 250))"
# Bind mounts, like the compose file; root-owned files from the container are
# removed from inside it.
BASE="$(mktemp -d)"
DATA="$BASE/data"
HOMEV="$BASE/home"

# What the image needs to run, as in docker-compose.incus.yml.
CAPS=(
	--cap-add ALL
	--security-opt apparmor=unconfined
	--security-opt seccomp=unconfined
	--security-opt systempaths=unconfined
	--cgroupns private
	--device /dev/fuse
)
RUN_FLAGS=(
	"${CAPS[@]}"
	--stop-timeout 120
	-e DIND_ENVIRONMENT_NAME=smokeenv
	-v "$DATA":/var/lib/incus
	-v "$HOMEV":/home/alpine
)

compose() {
	INCUS_NAME="$CNAME" INCUS_DATA="$BASE/compose/data" ALPINE_HOME="$BASE/compose/home" \
		INCUS_API_PORT="$CAPI" INCUS_UI_PORT="$CUI" \
		INCUS_NET_SUBNET="$CNET.0/24" INCUS_IPV4="$CNET.1" INCUS_NET_GATEWAY="$CNET.254" \
		docker compose -p "$CNAME" -f "$COMPOSE_YML" -f "$BASE/compose.override.yml" "$@"
}

cleanup() {
	docker rm -f "$MAIN" "$SECOND" "$ADDR" "$SLOW" >/dev/null 2>&1 || true
	[ ! -e "$BASE/compose.override.yml" ] || compose down -t 0 >/dev/null 2>&1 || true
	docker run --rm -u 0 --entrypoint sh -v "$BASE":/b "$IMAGE" -c 'rm -rf /b/data /b/home /b/addr /b/slow /b/compose' >/dev/null 2>&1 || true
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

# Under pipefail, `producer | grep -q` fails although grep matched when the
# producer, still writing after grep exited, dies of SIGPIPE (the likely cause
# of one tofu plan check failing, not reproduced): grep reads a captured string
# instead, grep -q P <<<"$(producer)".

# A running stop operation of an instance, in `incus operation list -f csv`.
stop_op_running() { awk '/Stopping instance/ && /RUNNING/ {found = 1} END {exit !found}'; }

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
	docker run --rm -u 0 --entrypoint sh -v "${2:-$DATA}":/d "$IMAGE" \
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
	[ -n "$(marker lst)" ] || fail "$1: instance lst was not shut down in order"
}

wait_instance() {
	local name="${1:-smk}" c="${2:-$MAIN}"
	for _ in $(seq 1 60); do
		if [ "$(docker exec "$c" incus list "^$name\$" -c s -f csv 2>/dev/null)" = RUNNING ]; then
			return 0
		fi
		sleep 1
	done
	fail "instance $name is not RUNNING (state: $(docker exec "$c" incus list "^$name\$" -c s -f csv 2>&1))"
}

# OpenTofu in ~/DIR of the main container, as alpine, on the local image:
#   tf_run DIR [NAME=VALUE...] tofu ARGS...
# provision = false: the guest scripts need a distribution and the network.
TF_ENV=(-e TF_INPUT=0 -e TF_IN_AUTOMATION=1 -e TF_VAR_instance_image=smoke -e TF_VAR_provision=false
	-e TF_VAR_wait_network_seconds=0 -e TF_VAR_instance_cpu=1 -e TF_VAR_instance_swap=32MiB)
tf_run() {
	local dir="$1"
	shift
	docker exec "${TF_ENV[@]}" -w "/home/alpine/$dir" "$MAIN" env "$@"
}

# Same checks after every start: the API, the instance and its memory limit.
check_state() {
	wait_ready
	wait_configured
	wait_instance
	wait_instance lst
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

# The host's per-user limits, shared by every instance: raised at the start
# (never lowered, so a host already above them is left alone).
for kv in fs/inotify/max_user_instances=1048576 fs/inotify/max_user_watches=1048576 kernel/keys/maxkeys=2000 kernel/keys/maxbytes=2000000; do
	have="$(in_main cat "/proc/sys/${kv%%=*}")"
	[ "$have" -ge "${kv#*=}" ] || fail "host ${kv%%=*} is $have, not raised to ${kv#*=}"
done
ok "host inotify and keyring limits at Incus' production values or above"

in_main sh -c 'test "$(cat /sys/fs/cgroup/cgroup.subtree_control)" = "$(cat /sys/fs/cgroup/cgroup.controllers)"' ||
	fail "cgroup controllers not delegated at the root"
in_main sh -c 'test -d /sys/fs/cgroup/init.scope' || fail "init.scope missing"
ok "cgroup v2: processes in init.scope, controllers enabled"

[ "$(in_main curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:8443/ui/)" = 200 ] || fail "web UI not served on /ui/"
grep -q '"auth":"untrusted"' <<<"$(in_main curl -sk https://127.0.0.1:8443/1.0)" || fail "API on 8443 not answering"
ok "API and web UI on 8443 (untrusted without a certificate)"

# The proxy on 8080 holds a generated, trusted certificate: no browser setup.
[ "$(in_main curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ui/)" = 200 ] || fail "web UI proxy not serving /ui/ on 8080"
grep -q '"auth":"trusted"' <<<"$(in_main curl -s http://127.0.0.1:8080/1.0)" || fail "web UI proxy is not a trusted client"
[ "$(in_main curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/1.0/instances)" = 200 ] || fail "web UI proxy cannot list instances"
[ "$(in_main sh -c 'incus config trust list --format csv | grep -c incus-ui')" = 1 ] || fail "incus-ui certificate not trusted exactly once"
# index.html alone proves little: the UI is its bundle, loaded by a script, and
# its events and consoles go over WebSocket.
bundle="$(in_main curl -s http://127.0.0.1:8080/ui/ | grep -oE '/ui/assets/index-[A-Za-z0-9_-]+\.js' | head -n 1 || true)"
[ -n "$bundle" ] || fail "web UI index.html names no /ui/assets/index-*.js bundle"
[ "$(in_main curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8080$bundle")" = 200 ] || fail "web UI bundle $bundle not served"
ws="$(in_main curl -s -o /dev/null -w '%{http_code}' --max-time 3 -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
	-H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' http://127.0.0.1:8080/1.0/events || true)"
[ "$ws" = 101 ] || fail "web UI proxy does not upgrade /1.0/events to WebSocket (HTTP $ws)"
ok "web UI on 8080 without a browser certificate (proxy trusted as incus-ui): bundle served, WebSocket upgraded"

[ "$(count 'could not open error log file')" = 0 ] || fail "nginx complains about its error log"
ok "web UI proxy starts without alerts"

# Image "smoke" in the incus of container $1. The instance's init, like systemd,
# does not stop on SIGTERM and halts on SIGPWR (see marker). With /root/stubborn
# it ignores SIGPWR as well.
import_smoke_image() {
	docker exec -i "$1" sh -c 'cat >/tmp/smoke-init' <<'INIT'
#!/bin/sh
rm -f /root/clean-shutdown
trap '' TERM INT HUP
trap 'if [ ! -e /root/stubborn ]; then sleep 1; date +%s >/root/clean-shutdown; date +%s >>/root/shutdowns; exit 0; fi' PWR
while :; do sleep 1; done
INIT
	# A rootfs from the container's own busybox: no registry needed.
	docker exec "$1" sh -c '
		set -e
		d=$(mktemp -d)
		mkdir -p "$d/rootfs/bin" "$d/rootfs/sbin" "$d/rootfs/etc" "$d/rootfs/lib" "$d/rootfs/proc" "$d/rootfs/sys" "$d/rootfs/dev" "$d/rootfs/tmp" "$d/rootfs/root" "$d/rootfs/run" "$d/rootfs/mnt"
		cp /bin/busybox "$d/rootfs/bin/busybox"
		cp /lib/ld-musl-*.so.1 "$d/rootfs/lib/"
		for a in sh cat sleep mount ls grep id date tr cut true rm touch test; do ln -s busybox "$d/rootfs/bin/$a"; done
		install -m 0755 /tmp/smoke-init "$d/rootfs/sbin/init"
		rm -f /tmp/smoke-init
		printf "architecture: %s\ncreation_date: %s\nproperties:\n  description: smoke\n  os: smoke\n" "$(uname -m)" "$(date +%s)" >"$d/metadata.yaml"
		tar -C "$d" -cf /tmp/smoke-image.tar metadata.yaml rootfs
		incus image import /tmp/smoke-image.tar --alias smoke >/dev/null
		rm -rf "$d" /tmp/smoke-image.tar
	'
}
import_smoke_image "$MAIN" || fail "building the instance image"
in_main incus launch smoke smk -c limits.memory=64MiB -c limits.cpu=1 -c boot.autostart=true >/dev/null ||
	fail "launching an instance with limits"
wait_instance
# Without boot.autostart, as `incus launch` leaves it: incus starts it again
# because it was running (volatile.last_state.power), after a stop as after a
# crash. check_state looks at it after every one of them.
in_main incus launch smoke lst >/dev/null || fail "launching an instance without boot.autostart"
wait_instance lst
[ -z "$(in_main incus config get lst boot.autostart)" ] || fail "lst has boot.autostart set"
ok "instances launched from a local image (smk with boot.autostart, lst without)"

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

# The template is used from a copy in the home, as documented: its state then
# lives next to the instance's data, outside the container.
grep -q '^OpenTofu v' <<<"$(in_main tofu version)" || fail "tofu is not in the image"
in_main cp -r /opt/incus-template/terraform /home/alpine/tf
tf_run tf tofu init -no-color >/dev/null || fail "tofu init"
grep -q '^/usr/share/terraform/plugins/' <<<"$(in_main find /home/alpine/tf/.terraform/providers -type l -exec readlink {} +)" ||
	fail "tofu init did not take the provider from the image's mirror"
ok "OpenTofu: init takes the provider from the image, no registry"

out="$(tf_run tf tofu test -no-color 2>&1)" || fail "tofu test: $out"
ok "OpenTofu: the template's unit tests pass in the image ($(tail -1 <<<"$out"))"

out="$(docker exec "${TF_ENV[@]}" -e TF_DATA_DIR=/tmp/tf-guard -e TF_VAR_instance_name=guard "$MAIN" sh -c \
	'tofu -chdir=/opt/incus-template/terraform init -no-color >/dev/null && tofu -chdir=/opt/incus-template/terraform plan -no-color' 2>&1)" &&
	fail "tofu plan ran in /opt/incus-template, where its state would be lost with the container"
grep -q 'Copy the template under your home first' <<<"$out" || fail "the /opt/incus-template guard did not say why: $out"
[ -z "$(in_main incus list '^guard$' -c n -f csv)" ] || fail "the /opt/incus-template guard let an instance through"
ok "OpenTofu: refuses to run from /opt/incus-template"

# Settings from terraform.tfvars (name, memory, address) and from TF_VAR_* (the
# rest); the fixed address is set on the eth0 the default profile defines.
bridge="$(in_main incus network get incusbr0 ipv4.address)"
ip4="${bridge%.*}.50"
printf 'instance_name   = "tf"\ninstance_memory = "64MiB"\ninstance_ipv4   = "%s"\n' "$ip4" |
	docker exec -i "$MAIN" sh -c 'cat >/home/alpine/tf/terraform.tfvars'
out="$(tf_run tf tofu apply -auto-approve -no-color 2>&1)" || fail "tofu apply: $out"
[ "$(in_main incus config get tf limits.memory)" = 64MiB ] || fail "tofu: limits.memory from terraform.tfvars not applied"
[ "$(in_main incus exec tf -- cat /sys/fs/cgroup/memory.max)" = 67108864 ] || fail "tofu: memory limit not enforced"
[ "$(in_main incus exec tf -- cat /sys/fs/cgroup/memory.swap.max)" = 33554432 ] || fail "tofu: instance_swap from TF_VAR_ not enforced"
[ "$(in_main incus config get tf security.nesting)" = true ] || fail "tofu: security.nesting not set"
[ "$(in_main incus config device get tf eth0 network)" = incusbr0 ] || fail "tofu: eth0 not taken from the profile"
[ "$(in_main incus config device get tf eth0 ipv4.address)" = "$ip4" ] || fail "tofu: instance_ipv4 not set on eth0"
[ "$(tf_run tf tofu output -raw name)" = tf ] || fail "tofu output name"
tf_run tf tofu plan -detailed-exitcode -no-color >/dev/null || fail "tofu: the plan right after the apply is not empty"
ok "OpenTofu: instance from terraform.tfvars and TF_VAR_* (limits, swap, the profile's eth0 with a fixed address), empty plan after it"

# Memory and swap changed on the running instance: in place, the memory limit
# at once, the swap (raw.lxc) from the instance's next start. terraform.tfvars
# wins over TF_ENV's TF_VAR_instance_swap.
in_main incus exec tf -- touch /root/keep
in_main sed -i 's/^instance_memory = .*/instance_memory = "96MiB"/' /home/alpine/tf/terraform.tfvars
in_main sh -c 'echo "instance_swap   = \"48MiB\"" >>/home/alpine/tf/terraform.tfvars'
out="$(tf_run tf tofu apply -auto-approve -no-color 2>&1)" || fail "tofu apply of a memory and swap change: $out"
grep -q '0 added, 1 changed, 0 destroyed' <<<"$out" || fail "tofu: a memory and swap change must be applied in place ($(grep -E '^(Plan|Apply)' <<<"$out"))"
[ "$(in_main incus exec tf -- cat /sys/fs/cgroup/memory.max)" = 100663296 ] || fail "tofu: the new memory limit is not live"
in_main incus exec tf -- test -e /root/keep || fail "tofu: a memory change replaced the instance"
in_main incus restart tf
wait_instance tf
[ "$(in_main incus exec tf -- cat /sys/fs/cgroup/memory.swap.max)" = 50331648 ] || fail "tofu: the new swap size is not in force after a restart of the instance"
in_main incus exec tf -- test -e /root/keep || fail "tofu: tf lost its data at its restart"
tf_run tf tofu plan -detailed-exitcode -no-color >/dev/null || fail "tofu: the plan after the restart of the instance is not empty"
ok "OpenTofu: memory changed in place on the running instance, swap from its restart"

# A provisioning that fails (alpine's script on the busybox image: no apk) fails
# the apply with the script's output and leaves the instance tainted, so the
# next apply replaces it.
in_main cp -r /opt/incus-template/terraform /home/alpine/tf-bad
tf_run tf-bad tofu init -no-color >/dev/null || fail "tofu init (tf-bad)"
out="$(tf_run tf-bad TF_VAR_instance_name=tf-bad TF_VAR_distro=alpine TF_VAR_provision=true tofu apply -auto-approve -no-color 2>&1)" &&
	fail "tofu: a failed provisioning did not fail the apply"
grep -q 'apk: not found' <<<"$out" || fail "tofu: the provisioning error does not carry the script's output: $out"
out="$(tf_run tf-bad TF_VAR_instance_name=tf-bad TF_VAR_distro=alpine TF_VAR_provision=true tofu plan -no-color 2>&1)" || true
grep -q 'is tainted, so it must be replaced' <<<"$out" || fail "tofu: the instance of a failed provisioning is not marked for replacement: $out"
tf_run tf-bad TF_VAR_instance_name=tf-bad TF_VAR_distro=alpine tofu destroy -auto-approve -no-color >/dev/null || fail "tofu destroy (tf-bad)"
[ -z "$(in_main incus list '^tf-bad$' -c n -f csv)" ] || fail "tofu destroy left tf-bad behind"
ok "OpenTofu: a failed provisioning fails the apply with the script's output, the instance tainted"

# A second state on the same name must not take tf over, nor delete it.
in_main cp -r /opt/incus-template/terraform /home/alpine/tf-dup
tf_run tf-dup tofu init -no-color >/dev/null || fail "tofu init (tf-dup)"
out="$(tf_run tf-dup TF_VAR_instance_name=tf tofu apply -auto-approve -no-color 2>&1)" &&
	fail "tofu: a second state created an instance named tf"
grep -q 'already exists' <<<"$out" || fail "tofu: a second state on the same name did not say why: $out"
tf_run tf-dup TF_VAR_instance_name=tf tofu destroy -auto-approve -no-color >/dev/null || fail "tofu destroy (tf-dup)"
in_main incus exec tf -- test -e /root/keep || fail "tofu: a second state on the same name touched tf"
ok "OpenTofu: a second state on the same name is refused and leaves the instance alone"

docker run -d --name "$SECOND" "${RUN_FLAGS[@]}" "$IMAGE" >/dev/null
for _ in $(seq 1 60); do
	[ "$(docker inspect -f '{{.State.Running}}' "$SECOND")" = false ] && break
	sleep 1
done
[ "$(docker inspect -f '{{.State.ExitCode}}' "$SECOND")" = 75 ] || fail "second container on the same data directory did not exit 75"
grep -q 'another incusd holds' <<<"$(docker logs "$SECOND" 2>&1)" || fail "second container did not say why"
grep -q RUNNING <<<"$(in_main incus list smk -c s -f csv)" || fail "first container lost its instance to the second"
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
	stop_op_running <<<"$(in_main incus operation list -f csv 2>/dev/null)" && break
	sleep 1
done
stop_op_running <<<"$(in_main incus operation list -f csv)" || fail "no running stop operation"
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

# tf went through every stop and crash above with its state in the home: the
# state still matches it, and destroy removes it.
wait_instance tf
in_main incus exec tf -- test -e /root/keep || fail "tofu: tf lost its data"
tf_run tf tofu plan -detailed-exitcode -no-color >/dev/null || fail "tofu: the state no longer matches tf after the restarts"
tf_run tf tofu destroy -auto-approve -no-color >/dev/null || fail "tofu destroy"
[ -z "$(in_main incus list '^tf$' -c n -f csv)" ] || fail "tofu destroy left tf behind"
ok "OpenTofu: after the stops and crashes the state still matches the instance; destroy removes it"

# The API bound to one address: the web UI proxy must go there. It went to
# 127.0.0.1, which only a wildcard listener answers on: 502 for everything.
mkdir -p "$BASE/addr/data" "$BASE/addr/home"
docker run -d --name "$ADDR" "${CAPS[@]}" -e INCUS_ENV_HTTPS_ADDRESS=127.0.0.2:8443 \
	-v "$BASE/addr/data":/var/lib/incus -v "$BASE/addr/home":/home/alpine "$IMAGE" >/dev/null
code=""
for _ in $(seq 1 90); do
	code="$(docker exec "$ADDR" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/1.0 2>/dev/null || true)"
	[ "$code" = 200 ] && break
	sleep 1
done
[ "$code" = 200 ] || fail "web UI proxy with INCUS_ENV_HTTPS_ADDRESS=127.0.0.2:8443: HTTP $code"
grep -q '"auth":"trusted"' <<<"$(docker exec "$ADDR" curl -s http://127.0.0.1:8080/1.0)" || fail "web UI proxy on 127.0.0.2:8443 is not a trusted client"
docker rm -f "$ADDR" >/dev/null
ok "web UI proxy follows an API bound to one address (127.0.0.2:8443)"

# An API that never answers (a client that hangs, over the real one; incusd
# itself runs): the entrypoint gives up after 120s of wall clock. It counted
# rounds, and with each `timeout 5 incus info` that was up to 22 minutes.
mkdir -p "$BASE/slow/data" "$BASE/slow/home"
printf '#!/bin/sh\nexec sleep 10\n' >"$BASE/slow/incus"
chmod 0755 "$BASE/slow/incus"
docker run -d --name "$SLOW" "${CAPS[@]}" -v "$BASE/slow/incus":/usr/bin/incus:ro \
	-v "$BASE/slow/data":/var/lib/incus -v "$BASE/slow/home":/home/alpine "$IMAGE" >/dev/null
start=$SECONDS
until grep -qF 'incus not answering after 120s' <<<"$(docker logs "$SLOW" 2>&1)"; do
	[ $((SECONDS - start)) -lt 180 ] || fail "API not answering: no give-up after 180s: $(docker logs --tail 5 "$SLOW" 2>&1)"
	sleep 2
done
elapsed=$((SECONDS - start))
docker rm -f "$SLOW" >/dev/null
ok "API not answering: the entrypoint gives up after ${elapsed}s (deadline 120s)"

# A stop in the first seconds, while the root side still sets up (here an
# lxcfs that never mounts: the entrypoint waits 5s for it before incusd) or
# incusd has not installed its signal handlers: SIGPWR is sent again until it
# lands. Sent once, it found no incusd, and the stop waited out the whole
# timeout with incusd running (measured: 45s with a 40s timeout).
mkdir -p "$BASE/slow/data" "$BASE/slow/home"
printf '#!/bin/sh\nexec sleep 600\n' >"$BASE/slow/lxcfs"
chmod 0755 "$BASE/slow/lxcfs"
for delay in 0 1 3 6; do
	docker run -d --name "$SLOW" "${CAPS[@]}" -e INCUS_ENV_SHUTDOWN_TIMEOUT=40 -v "$BASE/slow/lxcfs":/usr/bin/lxcfs:ro \
		-v "$BASE/slow/data":/var/lib/incus -v "$BASE/slow/home":/home/alpine "$IMAGE" >/dev/null
	sleep "$delay"
	start=$SECONDS
	docker stop -t 70 "$SLOW" >/dev/null
	took=$((SECONDS - start))
	log="$(docker logs "$SLOW" 2>&1)"
	rc="$(docker inspect -f '{{.State.ExitCode}}' "$SLOW")"
	# Before the trap is set nothing runs yet, and the shell dies of the signal.
	if [ "$rc" != 0 ] && { [ "$rc" != 143 ] || grep -q 'launching incus' <<<"$log"; }; then
		fail "stop ${delay}s after the start: exit $rc: $(tail -n 5 <<<"$log")"
	fi
	[ "$took" -lt 25 ] || fail "stop ${delay}s after the start took ${took}s: $(tail -n 5 <<<"$log")"
	! grep -q 'incusd still running' <<<"$log" || fail "stop ${delay}s after the start left incusd running"
	docker rm -f "$SLOW" >/dev/null
done
ok "docker stop 0-6s after the start, incusd not up yet: exit 0, incusd stopped, in under 25s"

# The compose file as the README runs it (devices, cgroup rules, the fixed
# address, published ports, healthcheck, stop_grace_period), through the
# commands a user runs: up, restart, stop/start, down/up. The data paths do not
# exist yet: Docker creates them, as root.
if [ ! -e /dev/loop-control ] || [ ! -e /dev/net/tun ]; then
	fail "docker-compose.incus.yml needs /dev/loop-control and /dev/net/tun on this host"
fi
printf 'services:\n  incus:\n    image: %s\n' "$IMAGE" >"$BASE/compose.override.yml"
compose up -d --wait --wait-timeout 180 >/dev/null 2>&1 || fail "compose up --wait: $(docker logs --tail 20 "$CNAME" 2>&1)"
[ "$(docker inspect -f '{{.Config.StopTimeout}}' "$CNAME")" = 120 ] || fail "compose: stop_grace_period is not the container's stop timeout"
[ "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$CNAME")" = unless-stopped ] || fail "compose: restart policy"
[ "$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CNAME")" = "$CNET.1" ] || fail "compose: INCUS_IPV4 not applied"
for _ in $(seq 1 60); do
	[ "$(docker exec "$CNAME" incus config get core.https_address 2>/dev/null)" = ":8443" ] && break
	sleep 1
done
grep -q '"auth":"untrusted"' <<<"$(curl -sk --max-time 5 "https://127.0.0.1:$CAPI/1.0")" || fail "compose: API not published on 127.0.0.1:$CAPI"
grep -q '"auth":"trusted"' <<<"$(curl -s --max-time 5 "http://127.0.0.1:$CUI/1.0")" || fail "compose: web UI proxy not published on 127.0.0.1:$CUI"
import_smoke_image "$CNAME" || fail "compose: building the instance image"
docker exec "$CNAME" incus launch smoke cmp -c limits.memory=64MiB >/dev/null || fail "compose: launching an instance"
wait_instance cmp "$CNAME"
ok "compose up: healthy, stop timeout 120s, fixed address, API and web UI published on loopback"

# After every lifecycle command: healthy, cmp RUNNING with its limit, one more
# shutdown in order recorded by its init, the UI's certificate trusted once.
shutdowns=0
compose_back() {
	for _ in $(seq 1 180); do
		[ "$(docker inspect -f '{{.State.Health.Status}}' "$CNAME" 2>/dev/null)" = healthy ] && break
		sleep 1
	done
	[ "$(docker inspect -f '{{.State.Health.Status}}' "$CNAME" 2>/dev/null)" = healthy ] || fail "compose $1: not healthy: $(docker logs --tail 20 "$CNAME" 2>&1)"
	wait_instance cmp "$CNAME"
	[ "$(docker exec "$CNAME" incus exec cmp -- cat /sys/fs/cgroup/memory.max)" = 67108864 ] || fail "compose $1: cmp lost its memory limit"
	shutdowns=$((shutdowns + 1))
	n="$(docker exec "$CNAME" incus exec cmp -- cat /root/shutdowns | grep -c .)" || true
	[ "$n" = "$shutdowns" ] || fail "compose $1: cmp shut down in order $n times, expected $shutdowns"
	[ "$(docker exec "$CNAME" sh -c 'incus config trust list -f csv | grep -c incus-ui')" = 1 ] || fail "compose $1: incus-ui not trusted exactly once"
	grep -q '"auth":"trusted"' <<<"$(curl -s --max-time 5 "http://127.0.0.1:$CUI/1.0")" || fail "compose $1: web UI proxy not back"
}

compose restart >/dev/null 2>&1 || fail "compose restart"
compose_back restart
ok "compose restart: instance shut down in order and back"

compose stop >/dev/null 2>&1 || fail "compose stop"
[ "$(docker inspect -f '{{.State.ExitCode}}' "$CNAME")" = 0 ] || fail "compose stop: exit $(docker inspect -f '{{.State.ExitCode}}' "$CNAME")"
compose start >/dev/null 2>&1 || fail "compose start"
compose_back "stop + start"
ok "compose stop + start: exit 0, instance back"

old_id="$(docker inspect -f '{{.Id}}' "$CNAME")"
start=$SECONDS
compose down >/dev/null 2>&1 || fail "compose down"
took=$((SECONDS - start))
! docker inspect "$CNAME" >/dev/null 2>&1 || fail "compose down left the container"
[ "$took" -lt 60 ] || fail "compose down took ${took}s"
compose up -d >/dev/null 2>&1 || fail "compose up after down"
[ "$(docker inspect -f '{{.Id}}' "$CNAME")" != "$old_id" ] || fail "compose up after down reused the container"
compose_back "down + up"
ok "compose down (${took}s) + up: a new container on the same data, instance back"

compose down >/dev/null 2>&1 || fail "compose down"
ok "compose down"

echo "all checks passed"
