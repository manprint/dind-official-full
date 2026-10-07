#!/usr/bin/env bash
#
# Creates an Alpine Incus container and provisions it as a development box:
# user (uid 1000 by default) with home and password, timezone, Italian locale
# and keyboard, ssh server, Docker + Compose, network debugging tools, rclone
# and fuse (user_allow_other).
#
#   create_incus_alpine.sh
#   INSTANCE_NAME=web INSTANCE_MEMORY=4GiB USER_PASSWORD=secret create_incus_alpine.sh
#
# Runs anywhere an `incus` client reaches the daemon: inside the incus
# container (/opt/incus-template) or on another machine (INCUS_REMOTE).
# Every setting below can be overridden from the environment.
set -euo pipefail

# ---- instance ------------------------------------------------------------
: "${INCUS_REMOTE:=}"                    # remote name; empty = the default remote
: "${INSTANCE_NAME:=alpine-dev}"         # also the hostname
: "${INSTANCE_IMAGE:=images:alpine/3.24}"
: "${INSTANCE_PROFILES:=default}"        # space separated
: "${INSTANCE_STORAGE_POOL:=}"           # empty = the profile's pool
: "${INSTANCE_NETWORK:=}"                # empty = the profile's network
: "${INSTANCE_IPV4:=}"                   # fixed address on the managed bridge, e.g. 10.10.200.50
: "${INSTANCE_MEMORY=2GiB}"              # limits.memory; set it empty for no limit
: "${INSTANCE_CPU=2}"                    # limits.cpu; set it empty for no limit
: "${INSTANCE_SWAP:=}"                    # swap the instance may use, e.g. 1GiB; 0 or off = none; empty = Incus default (none)
: "${INSTANCE_DISK_SIZE:=}"              # root disk size, e.g. 20GiB (needs a btrfs/lvm/zfs pool)
: "${INSTANCE_NESTING:=true}"            # security.nesting, needed by Docker
: "${INSTANCE_INTERCEPT:=true}"          # security.syscalls.intercept.mknod/setxattr/sysinfo (sysinfo: free, top of busybox see the limits)
: "${INSTANCE_PRIVILEGED:=false}"        # security.privileged
: "${INSTANCE_AUTOSTART:=true}"          # boot.autostart
: "${INSTANCE_CONFIG:=}"                 # extra "key=value key=value" instance config
: "${INSTANCE_SSH_PUBLISH_PORT:=}"       # also listen on this port of the incus host (proxy device) -> 22
: "${INSTANCE_RECREATE:=false}"          # delete an existing instance of that name first

# ---- guest ---------------------------------------------------------------
: "${USER_NAME:=alpine}"
: "${USER_UID:=1000}"
: "${USER_PASSWORD:=password}"
: "${USER_SHELL:=/bin/bash}"
: "${USER_SUDO:=true}"                   # sudo group access
: "${USER_SUDO_NOPASSWD:=false}"
: "${TIMEZONE:=Europe/Rome}"
: "${LOCALE:=it_IT.UTF-8}"
: "${KEYMAP:=it}"
: "${SSH_PASSWORD_AUTH:=yes}"            # yes|no
: "${SSH_PERMIT_ROOT:=no}"               # yes|no|prohibit-password
: "${INSTALL_DOCKER:=true}"
: "${DOCKER_LOG_MAX_SIZE:=10m}"
: "${DOCKER_LOG_MAX_FILE:=5}"
: "${INSTALL_NET_TOOLS:=true}"
: "${INSTALL_RCLONE:=true}"
: "${RCLONE_RELEASE:=current}"           # current, or a version such as v1.70.0
: "${EXTRA_PACKAGES:=}"                  # more apk packages, space separated
: "${WAIT_NETWORK_SECONDS:=90}"

REF="${INCUS_REMOTE:+$INCUS_REMOTE:}$INSTANCE_NAME"

log() { printf '\033[1;34m[create_incus_alpine]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[create_incus_alpine] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v incus >/dev/null || die "the incus client is not in PATH"
incus info "${INCUS_REMOTE:+$INCUS_REMOTE:}" >/dev/null 2>&1 || die "cannot reach the incus daemon (remote '${INCUS_REMOTE:-default}')"
case "$USER_NAME" in root | "") die "USER_NAME must not be root or empty" ;; esac

# memory.swap.max in bytes. Incus has no swap size for containers (limits.memory.swap
# is a bool, and with a memory limit the cgroup gets 0): the size goes into raw.lxc.
swap_bytes=""
case "$INSTANCE_SWAP" in
"") ;;
0 | off | none | no) swap_bytes=0 ;;
*)
	if [[ "$INSTANCE_SWAP" =~ ^([0-9]+)[[:space:]]*(B|K|KB|KiB|kB|M|MB|MiB|G|GB|GiB|T|TB|TiB)?$ ]]; then
		n="${BASH_REMATCH[1]}"
		case "${BASH_REMATCH[2]:-B}" in
		B) mul=1 ;;
		K | KiB) mul=1024 ;;
		kB | KB) mul=1000 ;;
		M | MiB) mul=1048576 ;;
		MB) mul=1000000 ;;
		G | GiB) mul=1073741824 ;;
		GB) mul=1000000000 ;;
		T | TiB) mul=1099511627776 ;;
		TB) mul=1000000000000 ;;
		esac
		swap_bytes=$((10#$n * mul))
	else
		die "INSTANCE_SWAP '$INSTANCE_SWAP' is not a size (e.g. 512MiB, 1GiB, 0)"
	fi
	;;
esac

# ---- create --------------------------------------------------------------
if incus info "$REF" >/dev/null 2>&1; then
	if [ "$INSTANCE_RECREATE" = true ]; then
		log "deleting the existing instance $REF"
		incus delete --force "$REF"
	else
		die "instance $REF already exists (INSTANCE_RECREATE=true replaces it)"
	fi
fi

launch=(launch "$INSTANCE_IMAGE" "$REF")
for p in $INSTANCE_PROFILES; do launch+=(-p "$p"); done
[ -z "$INSTANCE_STORAGE_POOL" ] || launch+=(-s "$INSTANCE_STORAGE_POOL")
[ -z "$INSTANCE_NETWORK" ] || launch+=(-n "$INSTANCE_NETWORK")
[ -z "$INSTANCE_MEMORY" ] || launch+=(-c "limits.memory=$INSTANCE_MEMORY")
[ -z "$INSTANCE_CPU" ] || launch+=(-c "limits.cpu=$INSTANCE_CPU")
if [ "$swap_bytes" = 0 ]; then
	launch+=(-c limits.memory.swap=false)
elif [ -n "$swap_bytes" ]; then
	launch+=(-c "raw.lxc=lxc.cgroup2.memory.swap.max = $swap_bytes")
fi
launch+=(-c "security.nesting=$INSTANCE_NESTING" -c "boot.autostart=$INSTANCE_AUTOSTART")
[ "$INSTANCE_PRIVILEGED" != true ] || launch+=(-c security.privileged=true)
if [ "$INSTANCE_INTERCEPT" = true ]; then
	launch+=(-c security.syscalls.intercept.mknod=true -c security.syscalls.intercept.setxattr=true -c security.syscalls.intercept.sysinfo=true)
fi
for kv in $INSTANCE_CONFIG; do launch+=(-c "$kv"); done
[ -z "$INSTANCE_DISK_SIZE" ] || launch+=(-d "root,size=$INSTANCE_DISK_SIZE")
[ -z "$INSTANCE_IPV4" ] || launch+=(-d "eth0,ipv4.address=$INSTANCE_IPV4")

log "launching $REF from $INSTANCE_IMAGE"
incus "${launch[@]}"

if [ -n "$INSTANCE_SSH_PUBLISH_PORT" ]; then
	incus config device add "$REF" ssh proxy \
		"listen=tcp:0.0.0.0:$INSTANCE_SSH_PUBLISH_PORT" connect=tcp:127.0.0.1:22
fi

# ---- wait for the network --------------------------------------------------
log "waiting for the network of $REF"
ready=false
for _ in $(seq 1 "$WAIT_NETWORK_SECONDS"); do
	if incus exec "$REF" -- sh -c 'getent hosts dl-cdn.alpinelinux.org >/dev/null 2>&1'; then
		ready=true
		break
	fi
	sleep 1
done
[ "$ready" = true ] || die "$REF has no working network/DNS after ${WAIT_NETWORK_SECONDS}s"

# ---- provision -------------------------------------------------------------
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cat >"$tmp" <<'GUEST'
#!/bin/sh
set -eu
say() { echo "[guest] $*"; }
is_true() { [ "$1" = true ] || [ "$1" = yes ] || [ "$1" = 1 ]; }

say "packages"
apk update
pkgs="bash bash-completion shadow sudo openssh tzdata musl-locales musl-locales-lang kbd-bkeymaps alpine-conf
	curl wget ca-certificates openssl git vim nano rsync unzip jq htop lsof fuse fuse3 $EXTRA_PACKAGES"
if is_true "$INSTALL_NET_TOOLS"; then
	pkgs="$pkgs iproute2 iputils bind-tools tcpdump traceroute mtr nmap nmap-ncat socat iperf3 ethtool net-tools conntrack-tools iptables nftables"
fi
if is_true "$INSTALL_DOCKER"; then
	pkgs="$pkgs docker docker-cli-compose docker-openrc"
fi
# shellcheck disable=SC2086 # one argument per package
apk add --no-cache $pkgs

say "hostname, timezone, locale, keyboard"
hostname "$INSTANCE_NAME" 2>/dev/null || true
echo "$INSTANCE_NAME" >/etc/hostname
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
echo "$TIMEZONE" >/etc/timezone
cat >/etc/profile.d/00-locale.sh <<EOF
export LANG=$LOCALE
export LC_ALL=$LOCALE
export LANGUAGE=${LOCALE%%.*}:${LOCALE%%_*}
EOF
chmod 0644 /etc/profile.d/00-locale.sh
# Console keymap (no console in a container: the files are what a login on one would read).
setup-keymap "$KEYMAP" "$KEYMAP" >/dev/null 2>&1 || true
rc-update del loadkmap boot >/dev/null 2>&1 || true
mkdir -p /etc/default
printf 'XKBLAYOUT="%s"\nXKBMODEL="pc105"\n' "$KEYMAP" >/etc/default/keyboard

say "aliases (every user)"
# profile.d: login shells, root's ash included. /etc/bash/*.sh: every interactive
# bash, login or not (Alpine's bash reads them from /etc/bash/bashrc, which also
# loads bash-completion).
printf '%s\n' "alias ll='ls -alFh'" >/etc/profile.d/10-aliases.sh
printf '%s\n' "alias ll='ls -alFh'" >/etc/bash/10-aliases.sh
chmod 0644 /etc/profile.d/10-aliases.sh /etc/bash/10-aliases.sh

say "user $USER_NAME ($USER_UID)"
if getent passwd "$USER_NAME" >/dev/null; then
	[ "$(id -u "$USER_NAME")" = "$USER_UID" ] || { echo "user $USER_NAME exists with another uid" >&2; exit 1; }
else
	if getent passwd "$USER_UID" >/dev/null; then
		echo "uid $USER_UID belongs to $(getent passwd "$USER_UID" | cut -d: -f1)" >&2
		exit 1
	fi
	addgroup -g "$USER_UID" "$USER_NAME" 2>/dev/null || true
	adduser -D -u "$USER_UID" -G "$USER_NAME" -h "/home/$USER_NAME" -s "$USER_SHELL" "$USER_NAME"
fi
echo "$USER_NAME:$USER_PASSWORD" | chpasswd
mkdir -p "/home/$USER_NAME"
chown "$USER_UID:$(id -g "$USER_NAME")" "/home/$USER_NAME"
if is_true "$USER_SUDO"; then
	addgroup -S wheel 2>/dev/null || true
	addgroup "$USER_NAME" wheel
	if is_true "$USER_SUDO_NOPASSWD"; then
		echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' >/etc/sudoers.d/wheel
	else
		echo '%wheel ALL=(ALL:ALL) ALL' >/etc/sudoers.d/wheel
	fi
	chmod 0440 /etc/sudoers.d/wheel
fi
cat >"/home/$USER_NAME/.profile" <<EOF
export LANG=$LOCALE
export LC_ALL=$LOCALE
EOF
chown "$USER_UID:$(id -g "$USER_NAME")" "/home/$USER_NAME/.profile"

say "ssh"
mkdir -p /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/10-template.conf <<EOF
PasswordAuthentication $SSH_PASSWORD_AUTH
PermitRootLogin $SSH_PERMIT_ROOT
UsePAM no
EOF
grep -q '^Include /etc/ssh/sshd_config.d' /etc/ssh/sshd_config ||
	sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
rc-update add sshd default >/dev/null
rc-service sshd restart >/dev/null 2>&1 || rc-service sshd start

say "fuse (user_allow_other)"
touch /etc/fuse.conf
sed -i 's/^#user_allow_other/user_allow_other/' /etc/fuse.conf
grep -q '^user_allow_other' /etc/fuse.conf || echo user_allow_other >>/etc/fuse.conf
if getent group fuse >/dev/null; then addgroup "$USER_NAME" fuse; fi

if is_true "$INSTALL_RCLONE"; then
	say "rclone"
	case "$(apk --print-arch)" in
		x86_64) arch=amd64 ;;
		aarch64) arch=arm64 ;;
		armv7) arch=arm-v7 ;;
		*) echo "no rclone build for $(apk --print-arch)" >&2; exit 1 ;;
	esac
	version="$RCLONE_RELEASE"
	if [ "$version" = current ]; then
		version="$(wget -qO- https://downloads.rclone.org/version.txt | awk '{print $2}')"
		[ -n "$version" ] || { echo "cannot read the current rclone version from downloads.rclone.org" >&2; exit 1; }
	fi
	dir="rclone-$version-linux-$arch"
	cd /tmp
	wget -qO "$dir.zip" "https://downloads.rclone.org/$version/$dir.zip"
	wget -qO rclone.sha256sums "https://downloads.rclone.org/$version/SHA256SUMS"
	grep " $dir\\.zip\$" rclone.sha256sums | sha256sum -c -
	unzip -qo "$dir.zip"
	install -m 0755 "$dir/rclone" /usr/local/bin/rclone
	rm -rf "$dir" "$dir.zip" rclone.sha256sums
	rclone version | head -1
fi

if is_true "$INSTALL_DOCKER"; then
	say "docker"
	mkdir -p /etc/docker
	cat >/etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "$DOCKER_LOG_MAX_SIZE", "max-file": "$DOCKER_LOG_MAX_FILE" }
}
EOF
	addgroup "$USER_NAME" docker
	# OpenRC leaves every process in the root cgroup, which then cannot hand
	# controllers to the cgroups Docker creates: `docker run -m/--cpus` fails
	# with "memory.max: no such file". Move them aside and enable the
	# controllers before dockerd starts (systemd images do this by themselves).
	# The target is named init.scope on purpose: lxcfs prunes that suffix when it
	# reads the usage of the instance (/proc/meminfo, free, top, htop); any other
	# name (it was "init") makes it read an empty cgroup, so everything shows
	# 0 used while the limit is right.
	cat >/etc/init.d/cgroup-delegate <<'SERVICE'
#!/sbin/openrc-run
description="Delegate the cgroup v2 controllers (limits of nested Docker containers)"
depend() {
	need cgroups
	before docker
}
start() {
	root=/sys/fs/cgroup
	[ -f "$root/cgroup.controllers" ] || return 0
	mkdir -p "$root/init.scope"
	tries=0
	while [ "$tries" -lt 25 ]; do
		for pid in $(cat "$root/cgroup.procs"); do
			echo "$pid" >"$root/init.scope/cgroup.procs" 2>/dev/null || true
		done
		ok=true
		for c in $(cat "$root/cgroup.controllers"); do
			echo "+$c" >"$root/cgroup.subtree_control" 2>/dev/null || ok=false
		done
		$ok && return 0
		tries=$((tries + 1))
		sleep 0.2
	done
	ewarn "could not delegate every cgroup controller"
	return 0
}
SERVICE
	chmod 0755 /etc/init.d/cgroup-delegate
	rc-update add cgroup-delegate boot >/dev/null
	rc-service cgroup-delegate start >/dev/null 2>&1 || true
	rc-update add docker default >/dev/null
	rc-service docker restart >/dev/null 2>&1 || rc-service docker start
	i=0
	while [ "$i" -lt 30 ] && ! docker info >/dev/null 2>&1; do i=$((i + 1)); sleep 1; done
	docker version --format 'docker {{.Server.Version}}'
	docker compose version
fi
say "done"
GUEST

log "provisioning $REF"
incus file push "$tmp" "$REF/root/provision.sh" --mode 0700
incus exec "$REF" \
	--env "INSTANCE_NAME=$INSTANCE_NAME" --env "USER_NAME=$USER_NAME" --env "USER_UID=$USER_UID" \
	--env "USER_PASSWORD=$USER_PASSWORD" --env "USER_SHELL=$USER_SHELL" \
	--env "USER_SUDO=$USER_SUDO" --env "USER_SUDO_NOPASSWD=$USER_SUDO_NOPASSWD" \
	--env "TIMEZONE=$TIMEZONE" --env "LOCALE=$LOCALE" --env "KEYMAP=$KEYMAP" \
	--env "SSH_PASSWORD_AUTH=$SSH_PASSWORD_AUTH" --env "SSH_PERMIT_ROOT=$SSH_PERMIT_ROOT" \
	--env "INSTALL_DOCKER=$INSTALL_DOCKER" --env "DOCKER_LOG_MAX_SIZE=$DOCKER_LOG_MAX_SIZE" \
	--env "DOCKER_LOG_MAX_FILE=$DOCKER_LOG_MAX_FILE" --env "INSTALL_NET_TOOLS=$INSTALL_NET_TOOLS" \
	--env "INSTALL_RCLONE=$INSTALL_RCLONE" --env "RCLONE_RELEASE=$RCLONE_RELEASE" \
	--env "EXTRA_PACKAGES=$EXTRA_PACKAGES" \
	-- /root/provision.sh
incus exec "$REF" -- rm -f /root/provision.sh

ip4="$(incus list "${INCUS_REMOTE:+$INCUS_REMOTE:}^$INSTANCE_NAME\$" -c 4 -f csv | tr ',' '\n' | tr -d '"' | awk '/\(eth0\)/ {print $1}')"
log "ready: $REF  ip=${ip4:-?}  user=$USER_NAME  password=$USER_PASSWORD"
log "ssh ${USER_NAME}@${ip4:-<ip>}${INSTANCE_SSH_PUBLISH_PORT:+   (or port $INSTANCE_SSH_PUBLISH_PORT of the incus host)}"
