#!/usr/bin/env bash
# shellcheck disable=SC2016 # single-quoted commands run in the guest's shell
#
# Nested workloads through the lifecycle of the Incus container:
#
#   tests/nested.incus.sh IMAGE [TEMPLATE]
#
# Starts IMAGE with docker-compose.incus.yml (own project, name, ports, network
# and data paths), creates an instance with /opt/incus-template/create_incus_
# TEMPLATE.sh (default debian13; alpine, ubuntu2404, ubuntu2604, fedora) and runs
# Docker workloads in it: a container with --restart unless-stopped, one with
# --restart always and a memory limit, and a Compose project. Then the commands
# a user runs on the outer container: compose restart, stop + start, down + up,
# and a crash (SIGKILL to its PID 1 from the host, brought back by the restart
# policy). After each: the outer container healthy, the instance RUNNING with
# its init healthy (systemd not degraded), the nested containers back, the
# memory limit in force, DNS through every layer, the data kept; after a
# graceful one, every nested container stopped by its own SIGTERM handler (the
# shutdown went docker stop -> incus -> the instance's init -> its Docker); after
# the crash, none did.
#
# Needs what smoke.incus.sh needs plus internet access (instance image, distro
# packages, Docker's repository), and a TMPDIR on ext4, xfs or btrfs: the data
# directory is made there, and the instance's Docker stacks overlayfs on it.
# The nested image is built from the Incus container's busybox: no registry.
# The template runs with its defaults (INSTALL_NET_TOOLS=false skips those).
# Everything is named incus-nst-<pid>-*; KEEP=1 leaves the outer container and
# its data behind after a failure.
set -euo pipefail

IMAGE="${1:?usage: $0 IMAGE [TEMPLATE]}"
TPL="${2:-debian13}"
case "$TPL" in alpine | debian13 | ubuntu2404 | ubuntu2604 | fedora) ;; *)
	echo "unknown template $TPL" >&2
	exit 2
	;;
esac
ID="incus-nst-$$"
CNAME="$ID"
NAME=nst
BASE="$(mktemp -d)"
COMPOSE_YML="$(cd "$(dirname "$0")/.." && pwd)/docker-compose.incus.yml"
CAPI=$((20000 + $$ % 20000))
CUI=$((CAPI + 1))
CNET="10.251.$(($$ % 250))"

compose() {
	INCUS_NAME="$CNAME" INCUS_DATA="$BASE/data" ALPINE_HOME="$BASE/home" \
		INCUS_API_PORT="$CAPI" INCUS_UI_PORT="$CUI" \
		INCUS_NET_SUBNET="$CNET.0/24" INCUS_IPV4="$CNET.1" INCUS_NET_GATEWAY="$CNET.254" \
		docker compose -p "$CNAME" -f "$COMPOSE_YML" -f "$BASE/compose.override.yml" "$@"
}

cleanup() {
	[ -z "${KEEP:-}" ] || {
		echo "KEEP: $CNAME left running, data in $BASE" >&2
		return
	}
	compose down -t 0 >/dev/null 2>&1 || true
	docker run --rm -u 0 --entrypoint sh -v "$BASE":/b "$IMAGE" -c 'rm -rf /b/data /b/home' >/dev/null 2>&1 || true
	rm -rf "$BASE"
}
trap cleanup EXIT

ok() { printf 'ok   - %s: %s\n' "$TPL" "$*"; }
fail() {
	printf 'FAIL - %s: %s\n' "$TPL" "$*" >&2
	docker logs --tail 30 "$CNAME" >&2 2>&1 || true
	exit 1
}

in_c() { docker exec "$CNAME" "$@"; }
# A shell command in the instance, as root.
g() { in_c incus exec "$NAME" -- sh -c "$1"; }

wait_healthy() {
	for _ in $(seq 1 180); do
		[ "$(docker inspect -f '{{.State.Health.Status}}' "$CNAME" 2>/dev/null)" = healthy ] && return 0
		sleep 1
	done
	fail "$1: outer container not healthy after 180s"
}

wait_guest() {
	for _ in $(seq 1 120); do
		if [ "$(in_c incus list "^$NAME\$" -c s -f csv 2>/dev/null)" = RUNNING ] && g 'docker info >/dev/null 2>&1'; then
			return 0
		fi
		sleep 1
	done
	fail "$1: instance $NAME or its Docker not up after 120s"
}

# Lines of a file in the volume of the nested containers. A failed exec (the
# instance just started) is retried, not read as 0 lines.
count() {
	local out
	for _ in 1 2 3 4 5; do
		if out="$(g "touch /var/lib/docker/volumes/nst-data/_data/$1 && cat /var/lib/docker/volumes/nst-data/_data/$1" 2>&1)"; then
			grep -c . <<<"$out" || true
			return 0
		fi
		sleep 2
	done
	fail "reading $1 in the guest: $out"
}

running() { g "docker inspect -f '{{.State.Running}}' $1 2>/dev/null" || true; }

echo "== $IMAGE, template $TPL"
# The instances' Docker stacks overlayfs on the data directory (dir pool).
case "$(stat -f -c %T "$BASE")" in overlayfs | nfs*)
	fail "$BASE is on $(stat -f -c %T "$BASE"): Docker in the instance needs ext4, xfs or btrfs there (TMPDIR=… $0)"
	;;
esac
printf 'services:\n  incus:\n    image: %s\n' "$IMAGE" >"$BASE/compose.override.yml"
compose up -d --wait --wait-timeout 180 >/dev/null 2>&1 || fail "compose up: $(docker logs --tail 20 "$CNAME" 2>&1)"
for _ in $(seq 1 90); do
	in_c sh -c 'incus profile show default | grep -q "type: disk"' 2>/dev/null && break
	sleep 1
done
ok "outer container up (compose), preseed applied"

out="$(in_c env INSTANCE_NAME="$NAME" INSTANCE_MEMORY=2GiB ${INSTALL_NET_TOOLS:+INSTALL_NET_TOOLS=$INSTALL_NET_TOOLS} \
	"/opt/incus-template/create_incus_$TPL.sh" 2>&1)" || fail "create_incus_$TPL.sh: $(tail -n 30 <<<"$out")"
wait_guest "after the template"
ok "instance created and provisioned by create_incus_$TPL.sh"

# busybox and its loader from the Incus container, imported on the guest's Docker.
docker exec "$CNAME" sh -c '
	set -e
	d=$(mktemp -d)
	mkdir -p "$d/bin" "$d/lib" "$d/data" "$d/tmp" "$d/etc"
	cp /bin/busybox "$d/bin/" && cp /lib/ld-musl-*.so.1 "$d/lib/"
	for a in sh cat sleep date echo hostname nslookup ping wget grep; do ln -s busybox "$d/bin/$a"; done
	tar -C "$d" -cf /tmp/bb.tar .
	rm -rf "$d"
'
in_c incus file push /tmp/bb.tar "$NAME/root/bb.tar" >/dev/null
out="$(g 'docker import /root/bb.tar nst-bb:local >/dev/null && rm -f /root/bb.tar' 2>&1)" || fail "docker import in the guest: $out"

# The nested containers' process, in their volume: a start line, and a stop
# line on SIGTERM (sleep in the background, so that the trap runs at once).
g 'docker volume create nst-data >/dev/null' || fail "docker volume create in the guest"
docker exec -i "$CNAME" incus exec "$NAME" -- sh -c 'cat >/var/lib/docker/volumes/nst-data/_data/run.sh' <<'RUN'
n=$1
echo "$(hostname) $(date +%s)" >>"/data/$n.starts"
trap 'date +%s >>"/data/$n.stops"; exit 0' TERM
while :; do sleep 1 & wait; done
RUN
docker exec -i "$CNAME" incus exec "$NAME" -- sh -c 'mkdir -p /root/app && cat >/root/app/compose.yml' <<'YML'
services:
  svc:
    image: nst-bb:local
    restart: unless-stopped
    command: ["sh", "/data/run.sh", "svc"]
    volumes: [nst-data:/data]
volumes:
  nst-data:
    external: true
YML
g 'docker run -d --name web --restart unless-stopped -v nst-data:/data nst-bb:local sh /data/run.sh web >/dev/null &&
	docker run -d --name job --restart always -m 64m -v nst-data:/data nst-bb:local sh /data/run.sh job >/dev/null &&
	cd /root/app && docker compose up -d >/dev/null' || fail "starting the nested workloads"
for c in web job app-svc-1; do
	for _ in $(seq 1 30); do
		[ "$(running "$c")" = true ] && break
		sleep 1
	done
	[ "$(running "$c")" = true ] || fail "nested container $c not running"
done
ok "nested workloads: web (unless-stopped), job (always, -m 64m), Compose service svc"

# After a cycle: everything back and $1 more SIGTERM-handled stops per workload.
starts=1
stops=0
check_back() {
	local what="$1" graceful="$2" c n
	wait_healthy "$what"
	wait_guest "$what"
	if [ "$TPL" != alpine ]; then
		state="$(g 'systemctl is-system-running --wait 2>/dev/null' || true)"
		[ "$state" = running ] || fail "$what: systemd in the guest is '$state': $(g 'systemctl --failed --no-legend --plain' 2>&1)"
	fi
	for c in web job app-svc-1; do
		for _ in $(seq 1 60); do
			[ "$(running "$c")" = true ] && break
			sleep 1
		done
		[ "$(running "$c")" = true ] || fail "$what: nested container $c not back"
	done
	starts=$((starts + 1))
	[ "$graceful" = yes ] && stops=$((stops + 1))
	for c in web job svc; do
		n="$(count "$c.starts")"
		[ "$n" = "$starts" ] || fail "$what: $c started $n times, expected $starts"
		n="$(count "$c.stops")"
		[ "$n" = "$stops" ] || fail "$what: $c stopped by SIGTERM $n times, expected $stops (graceful: $graceful)"
	done
	n="$(g 'docker exec job cat /sys/fs/cgroup/memory.max')"
	[ "$n" = 67108864 ] || fail "$what: nested memory limit is '$n'"
	# nested container -> guest Docker -> incus dnsmasq -> outer Docker DNS -> host
	g 'docker exec web nslookup deb.debian.org >/dev/null' || fail "$what: no DNS in a nested container"
}

compose restart >/dev/null 2>&1 || fail "compose restart"
check_back "compose restart" yes
ok "compose restart: nested containers stopped in order and back"

compose stop >/dev/null 2>&1 || fail "compose stop"
[ "$(docker inspect -f '{{.State.ExitCode}}' "$CNAME")" = 0 ] || fail "compose stop: exit $(docker inspect -f '{{.State.ExitCode}}' "$CNAME")"
compose start >/dev/null 2>&1 || fail "compose start"
check_back "compose stop + start" yes
ok "compose stop + start: exit 0, nested containers stopped in order and back"

compose down >/dev/null 2>&1 || fail "compose down"
compose up -d >/dev/null 2>&1 || fail "compose up after down"
check_back "compose down + up" yes
ok "compose down + up: a new outer container, nested containers stopped in order and back"

restarts="$(docker inspect -f '{{.RestartCount}}' "$CNAME")"
pid="$(docker inspect -f '{{.State.Pid}}' "$CNAME")"
docker run --rm --privileged --pid host -u 0 --entrypoint kill "$IMAGE" -KILL "$pid"
for _ in $(seq 1 60); do
	[ "$(docker inspect -f '{{.RestartCount}}' "$CNAME")" -gt "$restarts" ] && break
	sleep 1
done
[ "$(docker inspect -f '{{.RestartCount}}' "$CNAME")" -gt "$restarts" ] || fail "crash: the restart policy did not bring the container back"
check_back "crash of the outer container" no
ok "outer PID 1 SIGKILLed: back by the restart policy, nested containers restarted (no clean stop, as expected)"

compose down >/dev/null 2>&1 || fail "compose down"
echo "all checks passed"
