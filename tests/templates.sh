#!/usr/bin/env bash
# shellcheck disable=SC2016 # single-quoted commands run in the guest's shell
# Test of the instance templates shipped in the Incus image (/opt/incus-template):
#
#   tests/templates.sh IMAGE [TEMPLATE...]
#
# TEMPLATE is one of: alpine debian13 ubuntu2404 ubuntu2604 fedora (default: all).
# Starts the image on fresh bind mounts, runs each template with its defaults,
# checks the instance and deletes it. Per template: user, home, groups, timezone,
# Italian locale and keyboard, ssh (password login works, wrong password and root
# are refused), sudo asking for the password, Docker + Compose with memory and CPU
# limits, rclone and fuse allow_other, network tools, git/curl/ssh client, the `ll`
# alias and bash-completion for the user and root (login or not), the same after
# a restart of the instance, and a second run refused without INSTANCE_RECREATE.
#
# JREI=1 adds, per template, the init-system images of https://hub.docker.com/u/jrei
# (systemd Debian/Ubuntu/Fedora/CentOS, OpenRC Alpine) run on the Docker daemon of the
# instance, the documented way (tmpfs /tmp /run /run/lock, /sys/fs/cgroup bind-mounted
# rw, host cgroup namespace; with and without --privileged; --stop-signal SIGRTMIN+3 for systemd):
# each must boot, run a unit, stop gracefully and start again. JREI_IMAGES overrides the
# list; JREI_XFAIL lists images that are expected to fail (default: CentOS 7, whose
# systemd 219 cannot run on cgroup v2). About 1GB of pulls per template.
# Needs a Docker host that runs the Incus image (see smoke.incus.sh) and internet
# access: instance images, distro packages, Docker's repository, rclone. That is why
# it is not part of the release pipeline, whose smoke test needs no registry.
# SCRIPTS_DIR=scripts tests/templates.sh IMAGE tests the working tree instead of
# the scripts baked into the image. Everything is named incus-tpl-<pid>-*.
set -euo pipefail

IMAGE="${1:?usage: $0 IMAGE [TEMPLATE...]}"
shift || true
TEMPLATES=("$@")
[ "${#TEMPLATES[@]}" -gt 0 ] || TEMPLATES=(alpine debian13 ubuntu2404 ubuntu2604 fedora)
MAIN="incus-tpl-$$-main"
BASE="$(mktemp -d)"
PASSWORD=password

RUN_FLAGS=(
	--cap-add ALL
	--security-opt apparmor=unconfined
	--security-opt seccomp=unconfined
	--security-opt systempaths=unconfined
	--cgroupns private
	--device /dev/fuse
	--stop-timeout 120
	-v "$BASE/data":/var/lib/incus
	-v "$BASE/home":/home/alpine
)
if [ -n "${SCRIPTS_DIR:-}" ]; then
	RUN_FLAGS+=(-v "$(cd "$SCRIPTS_DIR" && pwd)":/opt/incus-template:ro)
fi

cleanup() {
	docker rm -f "$MAIN" >/dev/null 2>&1 || true
	docker run --rm -u 0 --entrypoint sh -v "$BASE":/b "$IMAGE" -c 'rm -rf /b/data /b/home' >/dev/null 2>&1 || true
	rm -rf "$BASE"
}
trap cleanup EXIT

NAME=""
TPL=""
ok() { printf 'ok   - %s: %s\n' "$TPL" "$*"; }
fail() {
	printf 'FAIL - %s: %s\n' "$TPL" "$*" >&2
	exit 1
}

in_main() { docker exec "$MAIN" "$@"; }
# A shell command in the instance, as root.
g() { in_main incus exec "$NAME" -- sh -c "$1"; }
# The same as the template user, in an explicit login bash (fresh groups, profile
# read). The command goes through stdin: no quoting through su.
gu() { printf '%s\n' "$1" | docker exec -i "$MAIN" incus exec "$NAME" -- su - "$USER_T" -c 'bash -l'; }

wait_ready() {
	for _ in $(seq 1 150); do
		in_main incus info >/dev/null 2>&1 && return 0
		sleep 1
	done
	echo "FAIL - incus not answering" >&2
	docker logs --tail 30 "$MAIN" >&2
	exit 1
}

# The first-start preseed (pool, bridge, default profile) runs after the API answers.
wait_preseed() {
	for _ in $(seq 1 90); do
		in_main sh -c 'incus profile show default | grep -q "type: disk"' 2>/dev/null && return 0
		sleep 1
	done
	echo "FAIL - the default profile has no root disk after 90s" >&2
	exit 1
}

wait_for() { # wait_for DESCRIPTION COMMAND
	for _ in $(seq 1 90); do
		g "$2" >/dev/null 2>&1 && return 0
		sleep 1
	done
	fail "$1 not ready after 90s"
}

# Password login over ssh from the Incus container itself, no sshpass: OpenSSH
# asks a helper for the password (SSH_ASKPASS_REQUIRE=force).
ssh_try() { # ssh_try USER PASSWORD [command]
	in_main sh -c '
		printf "#!/bin/sh\necho \"\$ASKPASS_PW\"\n" > /tmp/askpass && chmod +x /tmp/askpass
		ASKPASS_PW="$2" SSH_ASKPASS=/tmp/askpass SSH_ASKPASS_REQUIRE=force \
			ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
			-o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=10 \
			"$1@$3" "${4:-id -un}" < /dev/null
	' sh "$1" "$2" "$IP" "${3:-}"
}

# A script on stdin, run in the instance as root with bash.
gs() { docker exec -i "$MAIN" incus exec "$NAME" -- bash -s -- "$@"; }

# Images come from the host's Docker (pulled once per run, then loaded into every instance):
# Docker Hub's anonymous pull limit would not survive 5 templates x 10 images.
preload() { # preload IMAGE
	docker image inspect "$1" >/dev/null 2>&1 || docker pull -q "$1" >/dev/null || return 1
	docker save "$1" | docker exec -i "$MAIN" incus exec "$NAME" -- docker load -q >/dev/null
}

JREI_IMAGES="${JREI_IMAGES:-jrei/systemd-debian:12 jrei/systemd-debian:13 jrei/systemd-ubuntu:22.04 jrei/systemd-ubuntu:24.04 jrei/systemd-ubuntu:26.04 jrei/systemd-fedora:latest jrei/systemd-centos:8 jrei/systemd-centos:7 jrei/openrc-alpine:latest}"
JREI_XFAIL="${JREI_XFAIL:-jrei/systemd-centos:7}"
JREI_FAILED=0

# jrei images on the instance's Docker: boot, a unit, graceful stop, start again.
check_jrei() {
	for img in $JREI_IMAGES; do
		if ! preload "$img"; then
			printf 'FAIL - %s: %s: cannot pull it on the host or load it into the instance\n' "$TPL" "$img" >&2
			JREI_FAILED=$((JREI_FAILED + 1))
			continue
		fi
		for mode in unpriv priv; do
			res="$(gs "$img" "$mode" <<'JREI'
img=$1 mode=$2
n=jr-$$
kind=systemd
case "$img" in *openrc*) kind=openrc ;; esac
flags="--tmpfs /tmp --tmpfs /run --tmpfs /run/lock -v /sys/fs/cgroup:/sys/fs/cgroup:rw --cgroupns=host"
# systemd halts on SIGRTMIN+3 (SIGTERM only re-executes it); busybox init, on SIGTERM.
[ "$kind" = systemd ] && flags="$flags --stop-signal SIGRTMIN+3"
[ "$mode" = priv ] && flags="--privileged $flags"
docker rm -f "$n" >/dev/null 2>&1
docker image inspect "$img" >/dev/null 2>&1 || { echo "FAIL image not loaded"; exit 0; }
# shellcheck disable=SC2086
if ! out="$(docker run -d --name "$n" $flags "$img" 2>&1)"; then echo "FAIL run: $out"; exit 0; fi
booted() {
	for _ in $(seq 1 60); do
		[ "$(docker inspect -f '{{.State.Running}}' "$n" 2>/dev/null)" = true ] || { echo "exited ($(docker inspect -f '{{.State.ExitCode}}' "$n"))"; return 1; }
		if [ "$kind" = systemd ]; then
			st="$(docker exec "$n" systemctl is-system-running 2>&1 | head -1)"
			case "$st" in running | degraded) echo "$st"; return 0 ;; esac
		else
			if docker exec "$n" rc-status -r 2>/dev/null | grep -q default; then echo "default runlevel"; return 0; fi
		fi
		sleep 1
	done
	echo "not ready after 60s (${st:-?})"
	return 1
}
if ! state="$(booted)"; then
	echo "FAIL boot: $state; $(docker logs --tail 3 "$n" 2>&1 | tr '\n' ' ')"
	docker rm -f "$n" >/dev/null 2>&1
	exit 0
fi
if [ "$kind" = systemd ]; then
	[ "$(docker exec "$n" cat /proc/1/comm)" = systemd ] || { echo "FAIL pid 1 is not systemd"; docker rm -f "$n" >/dev/null; exit 0; }
	# A oneshot unit, not systemd-run: Fedora's image has no D-Bus broker.
	docker exec "$n" sh -c 'printf "[Service]\nType=oneshot\nExecStart=/bin/touch /tmp/unit-ran\n" >/etc/systemd/system/jrei-test.service && systemctl start jrei-test.service && test -f /tmp/unit-ran' >/dev/null 2>&1 ||
		{ echo "FAIL a oneshot unit did not run"; docker rm -f "$n" >/dev/null; exit 0; }
	[ "$(docker exec "$n" systemctl is-active systemd-journald 2>&1)" = active ] || { echo "FAIL journald not active"; docker rm -f "$n" >/dev/null; exit 0; }
	failed="$(docker exec "$n" systemctl --failed --no-legend 2>/dev/null | wc -l)"
	detail="state $state, unit ran, journald active, $failed failed unit(s)"
else
	docker exec "$n" rc-service crond status >/dev/null 2>&1 || docker exec "$n" rc-status >/dev/null 2>&1 || { echo "FAIL rc-status"; docker rm -f "$n" >/dev/null; exit 0; }
	detail="OpenRC up ($state)"
fi
t0=$(date +%s)
docker stop -t 30 "$n" >/dev/null 2>&1
took=$(($(date +%s) - t0))
code="$(docker inspect -f '{{.State.ExitCode}}' "$n")"
# Exit 130 (systemd on SIGRTMIN+3) and 129 (busybox init on SIGTERM) in a privileged container,
# and CentOS 8 ignoring SIGRTMIN+3 without --privileged: the same on a plain Docker host.
stopnote=""
if [ "$took" -gt 15 ] || { [ "$code" != 0 ] && [ "$code" != 130 ] && [ "$code" != 129 ]; }; then
	case "$img:$mode" in
	jrei/systemd-centos:8:unpriv) stopnote=" (stop needed SIGKILL after ${took}s, as on a plain Docker host)" ;;
	*) echo "FAIL stop took ${took}s exit $code"; docker rm -f "$n" >/dev/null; exit 0 ;;
	esac
fi
docker start "$n" >/dev/null 2>&1
if ! again="$(booted)"; then echo "FAIL restart: $again"; docker rm -f "$n" >/dev/null; exit 0; fi
docker rm -f "$n" >/dev/null 2>&1
echo "ok $detail; docker stop ${took}s exit $code$stopnote; started again ($again)"
JREI
)" || res="FAIL script error"
			res="$(printf '%s' "$res" | tail -1)"
			case "$res" in
			ok*) ok "$img ($mode): ${res#ok }" ;;
			*)
				case " $JREI_XFAIL " in
				*" $img "*) echo "xfail - $TPL: $img ($mode): ${res#FAIL }" ;;
				*)
					printf 'FAIL - %s: %s (%s): %s\n' "$TPL" "$img" "$mode" "${res#FAIL }" >&2
					JREI_FAILED=$((JREI_FAILED + 1))
					;;
				esac
				;;
			esac
		done
		in_main incus exec "$NAME" -- docker rmi -f "$img" >/dev/null 2>&1 || true
	done
}

# The IPv4 of the instance: after a start it takes a moment to get one.
refresh_ip() {
	for _ in $(seq 1 60); do
		IP="$(in_main incus list "$NAME" -c 4 -f csv | tr ',' '\n' | tr -d '"' | awk '/\(eth0\)/ {print $1; exit}')"
		[ -z "$IP" ] || return 0
		sleep 1
	done
	fail "no IPv4 address"
}

# What an interactive ssh session (a login shell on a tty) sees as $LANG.
ssh_login() { # ssh_login USER PASSWORD
	printf '%s\n' 'echo "RES""ULT=$LANG"' exit | docker exec -i "$MAIN" sh -c '
		printf "#!/bin/sh\necho \"\$ASKPASS_PW\"\n" > /tmp/askpass && chmod +x /tmp/askpass
		ASKPASS_PW="$2" SSH_ASKPASS=/tmp/askpass SSH_ASKPASS_REQUIRE=force \
			ssh -tt -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
			-o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=10 \
			"$1@$3"
	' sh "$1" "$2" "$IP" | tr -d '\r' | sed -n 's/^RESULT=//p' | tail -1
}

# Checks that do not depend on the clock of the instance's boot: run twice,
# before and after a restart.
check_swap() {
	[ "$(g 'cat /sys/fs/cgroup/memory.swap.max')" = 1073741824 ] || fail "memory.swap.max ($1)"
	[ "$(g "free -m | awk '/^Mem:/ {print \$2}'")" = 2048 ] || fail "free: Mem total is not the 2GiB limit ($1)"
	[ "$(g "free -m | awk '/^Swap:/ {print \$2}'")" = 1024 ] || fail "free: Swap total is not 1024 ($1)"
	[ "$(g "awk '/^SwapTotal:/ {print \$2}' /proc/meminfo")" = 1048576 ] || fail "/proc/meminfo SwapTotal ($1)"
	ok "swap 1GiB: cgroup, /proc/meminfo and free agree, memory 2GiB ($1)"
}

# The limits are what every tool reports, and the numbers move with the real usage:
# /proc/meminfo (lxcfs: top, htop, procps free), sysinfo() (busybox free/top) and the
# cgroup agree. A process holding 300MB of anonymous memory must show everywhere.
# (Not tmpfs: free counts that as shared/cache, not as used.)
check_memory() {
	[ "$(g 'cat /sys/fs/cgroup/memory.max')" = 2147483648 ] || fail "memory.max ($1)"
	[ "$(g "awk '/^MemTotal:/ {print \$2}' /proc/meminfo")" = 2097152 ] || fail "/proc/meminfo MemTotal ($1)"
	[ "$(g 'nproc')" = 2 ] || fail "nproc is not the 2 CPUs of the limit ($1)"
	[ "$(g 'grep -c ^processor /proc/cpuinfo')" = 2 ] || fail "/proc/cpuinfo does not show 2 CPUs ($1)"
	[ "$(g "free -m | awk '/^Mem:/ {print \$2}'")" = 2048 ] || fail "free: Mem total is not 2048 ($1)"
	out="$(g '
b=$(free -m | awk "/^Mem:/ {print \$3}")
dd if=/dev/zero bs=300M count=1 2>/dev/null | sleep 12 &
sleep 4
a=$(free -m | awk "/^Mem:/ {print \$3}")
cg=$(cat /sys/fs/cgroup/memory.current)
mi=$(awk "/^MemTotal:/ {t=\$2} /^MemFree:/ {f=\$2} END {print int((t-f)/1024)}" /proc/meminfo)
tu=$(busybox top -bn1 2>/dev/null | sed -n "1s/^Mem: \([0-9]*\)K used.*/\1/p")
echo "$b $a $cg $mi ${tu:-0}"
wait')"
	read -r before after cg meminfo top_used <<<"$out"
	[ "$((after - before))" -ge 250 ] || fail "free: used went from $before to $after MiB with 300MiB allocated ($1)"
	[ "$meminfo" -ge 250 ] || fail "/proc/meminfo: only $meminfo MiB used with 300MiB allocated ($1)"
	[ "$((cg / 1048576))" -ge 250 ] || fail "memory.current is $((cg / 1048576)) MiB ($1)"
	if [ "$top_used" -gt 0 ]; then [ "$((top_used / 1024))" -ge 250 ] || fail "busybox top: ${top_used}K used ($1)"; fi
	ok "memory 2GiB and 2 CPUs: /proc/meminfo, free$([ "$top_used" -gt 0 ] && echo " and busybox top") and the cgroup agree; 300MiB allocated show as used ($((after - before)) MiB in free)"
}

check_services() {
	wait_for "sshd" "$SSH_ACTIVE"
	wait_for "docker" 'docker info'
	g 'docker image inspect alpine >/dev/null 2>&1' || preload alpine || fail "cannot get the alpine image for the limits test"
	[ "$(ssh_try "$USER_T" "$PASSWORD")" = "$USER_T" ] || fail "ssh password login ($1)"
	[ "$(gu 'docker run --rm -m 100m --cpus 0.5 alpine cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/cpu.max | tr "\n" " "')" = "104857600 50000 100000 " ] ||
		fail "docker run -m/--cpus limits ($1)"
	ok "ssh and Docker up, container limits enforced ($1)"
}

verify() {
	case "$TPL" in
	alpine) USER_T=alpine NAME=alpine-dev ADMIN_GROUP=wheel SSH_ACTIVE='rc-service sshd status' GLIBC=false ;;
	debian13) USER_T=debian NAME=debian13-dev ADMIN_GROUP=sudo SSH_ACTIVE='systemctl is-active --quiet ssh' GLIBC=true ;;
	ubuntu2404) USER_T=ubuntu NAME=ubuntu2404-dev ADMIN_GROUP=sudo SSH_ACTIVE='systemctl is-active --quiet ssh' GLIBC=true ;;
	ubuntu2604) USER_T=ubuntu NAME=ubuntu2604-dev ADMIN_GROUP=sudo SSH_ACTIVE='systemctl is-active --quiet ssh' GLIBC=true ;;
	fedora) USER_T=fedora NAME=fedora-dev ADMIN_GROUP=wheel SSH_ACTIVE='systemctl is-active --quiet sshd' GLIBC=true ;;
	*) echo "unknown template $TPL" >&2; exit 2 ;;
	esac
	# Not the default name of the template: leaves an instance of yours alone.
	NAME="tpl-$NAME"

	# A bad swap size is refused before anything is launched.
	if in_main env INSTANCE_NAME="$NAME" INSTANCE_SWAP=lots "/opt/incus-template/create_incus_$TPL.sh" >/dev/null 2>&1; then
		fail "INSTANCE_SWAP=lots accepted"
	fi
	in_main incus info "$NAME" >/dev/null 2>&1 && fail "an instance exists after a refused INSTANCE_SWAP"
	ok "INSTANCE_SWAP=lots refused, nothing launched"

	start=$(date +%s)
	in_main env INSTANCE_NAME="$NAME" INSTANCE_SWAP=1GiB "/opt/incus-template/create_incus_$TPL.sh" >"$BASE/$TPL.log" 2>&1 ||
		{ tail -30 "$BASE/$TPL.log" >&2; fail "template failed"; }
	ok "created and provisioned in $(($(date +%s) - start))s"
	refresh_ip

	# user and home
	[ "$(g "id -u $USER_T")" = 1000 ] || fail "uid of $USER_T"
	g "test -d /home/$USER_T && [ \"\$(stat -c %u /home/$USER_T)\" = 1000 ]" || fail "home of $USER_T"
	[ "$(g "getent passwd $USER_T | cut -d: -f7")" = /bin/bash ] || fail "shell of $USER_T"
	g "id -nG $USER_T | tr ' ' '\n' | grep -qx $ADMIN_GROUP" || fail "$USER_T not in $ADMIN_GROUP"
	g "id -nG $USER_T | tr ' ' '\n' | grep -qx docker" || fail "$USER_T not in docker"
	ok "user $USER_T uid 1000, home, bash, groups $ADMIN_GROUP and docker"

	# time, locale, keyboard
	g 'readlink -f /etc/localtime | grep -q "Europe/Rome$"' || fail "timezone"
	g 'date +%Z | grep -qE "^CES?T$"' || fail "date is not CET/CEST"
	got="$(gu 'echo $LANG $LC_ALL')"
	[ "$got" = "it_IT.UTF-8 it_IT.UTF-8" ] || fail "LANG/LC_ALL in a login shell (got '$got')"
	if [ "$GLIBC" = true ]; then g 'locale -a | grep -qi "^it_IT\.utf-\?8$"' || fail "locale it_IT.UTF-8 not generated"; fi
	g 'grep -q "XKBLAYOUT=\"it\"" /etc/default/keyboard' || fail "keyboard layout"
	ok "Europe/Rome, it_IT.UTF-8, keyboard it"

	# ssh
	wait_for "sshd" "$SSH_ACTIVE"
	[ "$(ssh_try "$USER_T" "$PASSWORD")" = "$USER_T" ] || fail "ssh password login"
	[ "$(ssh_login "$USER_T" "$PASSWORD")" = "it_IT.UTF-8" ] || fail "LANG in an interactive ssh session"
	ssh_try "$USER_T" wrong >/dev/null 2>&1 && fail "ssh accepted a wrong password"
	ssh_try root "$PASSWORD" >/dev/null 2>&1 && fail "ssh accepted root"
	ok "ssh: password login, wrong password and root refused, locale over ssh"

	# sudo asks for the password
	g "su - $USER_T -c 'sudo -n true' 2>/dev/null" && fail "sudo without a password"
	[ "$(g "su - $USER_T -c 'echo $PASSWORD | sudo -S -k id -u 2>/dev/null'")" = 0 ] || fail "sudo with the password"
	ok "sudo asks for the password and works with it"

	# tools
	for c in ip ping dig tcpdump traceroute mtr nmap nc socat iperf3 ethtool netstat ss conntrack iptables nft \
		git curl wget rsync unzip jq htop lsof vim nano ssh scp ssh-keygen rclone; do
		g "command -v $c" >/dev/null 2>&1 || fail "$c missing"
	done
	g 'grep -q "^user_allow_other" /etc/fuse.conf' || fail "user_allow_other"
	g 'command -v fusermount3 || command -v fusermount' >/dev/null || fail "fusermount missing"
	g 'rclone version | head -1' | grep -q '^rclone v' || fail "rclone does not run"
	ok "network tools, git/curl/ssh client, rclone, fuse user_allow_other"

	# alias and completion, user and root, login and not
	for who in "$USER_T" root; do
		[ "$(g "su $who -s /bin/bash -c \"bash -ic 'alias ll' 2>/dev/null\"")" = "alias ll='ls -alFh'" ] || fail "ll for $who (non-login bash)"
		[ "$(g "su - $who -s /bin/bash -c \"bash -lic 'alias ll' 2>/dev/null\"")" = "alias ll='ls -alFh'" ] || fail "ll for $who (login bash)"
		[ "$(g "su $who -s /bin/bash -c \"bash -ic 'complete | wc -l' 2>/dev/null\"")" -gt 0 ] || fail "no bash-completion for $who (non-login bash)"
		[ "$(g "su - $who -s /bin/bash -c \"bash -lic 'complete | wc -l' 2>/dev/null\"")" -gt 0 ] || fail "no bash-completion for $who (login bash)"
	done
	g "su - root -c 'alias ll'" | grep -q "ls -alFh" || fail "ll in root's own login shell"
	ok "alias ll and bash-completion for $USER_T and root, login and non-login"

	check_swap "first boot"
	check_memory "first boot"

	# The swap is real: 2.4GiB of tmpfs in a 2GiB instance only fits by swapping.
	if awk 'NR > 1 {found = 1} END {exit !found}' /proc/swaps; then
		g 'mkdir -p /mnt/swaptest && mount -t tmpfs -o size=3g tmpfs /mnt/swaptest && dd if=/dev/zero of=/mnt/swaptest/f bs=1M count=2400 2>/dev/null' ||
			fail "writing 2.4GiB of tmpfs failed: no usable swap"
		used="$(g 'cat /sys/fs/cgroup/memory.swap.current')"
		g 'rm -f /mnt/swaptest/f; umount /mnt/swaptest'
		[ "$used" -gt 0 ] || fail "memory.swap.current is 0 after exceeding the memory limit"
		ok "swap used under pressure ($((used / 1048576)) MiB swapped out)"
	else
		echo "skip - $TPL: the host has no swap, usage not tested"
	fi

	check_services "first boot"

	# a restart: services and limits come back
	in_main incus restart "$NAME"
	wait_for "the instance" 'true'
	refresh_ip
	check_swap "after restart"
	check_memory "after restart"
	check_services "after restart"

	# a second run without INSTANCE_RECREATE must refuse
	if in_main env INSTANCE_NAME="$NAME" "/opt/incus-template/create_incus_$TPL.sh" >/dev/null 2>&1; then
		fail "second run on an existing instance succeeded"
	fi
	ok "second run refused without INSTANCE_RECREATE"

	if [ "${JREI:-0}" = 1 ]; then check_jrei; fi

	in_main incus delete -f "$NAME" >/dev/null
}

echo "== $IMAGE"
mkdir -p "$BASE/data" "$BASE/home"
docker run -d --name "$MAIN" "${RUN_FLAGS[@]}" "$IMAGE" >/dev/null
wait_ready
wait_preseed
for TPL in "${TEMPLATES[@]}"; do
	verify
done
if [ "$JREI_FAILED" -gt 0 ]; then
	echo "FAIL - $JREI_FAILED jrei image run(s) failed" >&2
	exit 1
fi
echo "all templates passed: ${TEMPLATES[*]}"
