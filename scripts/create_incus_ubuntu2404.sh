#!/usr/bin/env bash
#
# Creates an Ubuntu 24.04 LTS (noble) Incus container and provisions it as a development box:
# user (uid 1000 by default) with home and password, timezone, Italian locale
# and keyboard, ssh server, Docker + Compose, network debugging tools, rclone
# and fuse (user_allow_other).
#
#   create_incus_ubuntu2404.sh
#   INSTANCE_NAME=web INSTANCE_MEMORY=4GiB USER_PASSWORD=secret create_incus_ubuntu2404.sh
#
# Runs anywhere an `incus` client reaches the daemon: inside the incus
# container (/opt/incus-template) or on another machine (INCUS_REMOTE).
# Every setting below can be overridden from the environment.
set -euo pipefail

# ---- instance ------------------------------------------------------------
: "${INCUS_REMOTE:=}"                    # remote name; empty = the default remote
: "${INSTANCE_NAME:=ubuntu2404-dev}"         # also the hostname
: "${INSTANCE_IMAGE:=images:ubuntu/24.04}"
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
: "${USER_NAME:=ubuntu}"
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
: "${DOCKER_SOURCE:=official}"           # official (download.docker.com, docker-ce) | distro (docker.io)
: "${DOCKER_LOG_MAX_SIZE:=10m}"
: "${DOCKER_LOG_MAX_FILE:=5}"
: "${INSTALL_NET_TOOLS:=true}"
: "${INSTALL_RCLONE:=true}"
: "${RCLONE_RELEASE:=current}"           # current, or a version such as v1.70.0
: "${EXTRA_PACKAGES:=}"                  # more apt packages, space separated
: "${WAIT_NETWORK_SECONDS:=90}"

REF="${INCUS_REMOTE:+$INCUS_REMOTE:}$INSTANCE_NAME"

log() { printf '\033[1;34m[create_incus_ubuntu2404]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[create_incus_ubuntu2404] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

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
	if incus exec "$REF" -- sh -c 'getent hosts archive.ubuntu.com >/dev/null 2>&1'; then
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
export DEBIAN_FRONTEND=noninteractive
say() { echo "[guest] $*"; }
is_true() { [ "$1" = true ] || [ "$1" = yes ] || [ "$1" = 1 ]; }

say "packages"
apt-get update -qq
pkgs="sudo procps openssh-server tzdata locales keyboard-configuration console-setup kbd
	curl wget ca-certificates gnupg openssl git vim nano rsync unzip jq htop lsof fuse3 bash-completion $EXTRA_PACKAGES"
if is_true "$INSTALL_NET_TOOLS"; then
	pkgs="$pkgs iproute2 iputils-ping traceroute mtr-tiny tcpdump nmap netcat-openbsd socat iperf3 dnsutils ethtool net-tools conntrack iptables nftables"
fi
# shellcheck disable=SC2086 # one argument per package
apt-get install -y -qq --no-install-recommends $pkgs

say "hostname, timezone, locale, keyboard"
hostname "$INSTANCE_NAME" 2>/dev/null || true
echo "$INSTANCE_NAME" >/etc/hostname
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
echo "$TIMEZONE" >/etc/timezone
sed -i "s/^# *\\($LOCALE \\)/\\1/" /etc/locale.gen
grep -q "^$LOCALE " /etc/locale.gen || echo "$LOCALE UTF-8" >>/etc/locale.gen
locale-gen >/dev/null
update-locale "LANG=$LOCALE" "LC_ALL=$LOCALE" "LANGUAGE=${LOCALE%%.*}:${LOCALE%%_*}"
cat >/etc/default/keyboard <<EOF
XKBMODEL="pc105"
XKBLAYOUT="$KEYMAP"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF
echo "KEYMAP=$KEYMAP" >/etc/vconsole.conf
echo "keyboard-configuration keyboard-configuration/layoutcode string $KEYMAP" | debconf-set-selections
dpkg-reconfigure -f noninteractive keyboard-configuration >/dev/null 2>&1 || true

say "aliases (every user)"
# profile.d: login shells; /etc/bash.bashrc: every interactive bash, login or not.
printf '%s\n' "alias ll='ls -alFh'" >/etc/profile.d/10-aliases.sh
chmod 0644 /etc/profile.d/10-aliases.sh
# The same file turns bash-completion on for root and any user whose ~/.bashrc does not.
grep -q 'incus-template aliases' /etc/bash.bashrc ||
	cat >>/etc/bash.bashrc <<'BASHRC'

# incus-template aliases
alias ll='ls -alFh'
if ! shopt -oq posix && [ -r /usr/share/bash-completion/bash_completion ]; then
	. /usr/share/bash-completion/bash_completion
fi
BASHRC

say "user $USER_NAME ($USER_UID)"
if getent passwd "$USER_NAME" >/dev/null; then
	[ "$(id -u "$USER_NAME")" = "$USER_UID" ] || { echo "user $USER_NAME exists with another uid" >&2; exit 1; }
else
	if getent passwd "$USER_UID" >/dev/null; then
		echo "uid $USER_UID belongs to $(getent passwd "$USER_UID" | cut -d: -f1)" >&2
		exit 1
	fi
	getent group "$USER_UID" >/dev/null || groupadd -g "$USER_UID" "$USER_NAME"
	useradd -m -u "$USER_UID" -g "$USER_UID" -d "/home/$USER_NAME" -s "$USER_SHELL" "$USER_NAME"
fi
# Ubuntu images may ship a user with this name and uid already, without a home.
if [ ! -d "/home/$USER_NAME" ]; then
	mkdir -p "/home/$USER_NAME"
	cp -rT /etc/skel "/home/$USER_NAME"
	chown -R "$USER_UID:$(id -g "$USER_NAME")" "/home/$USER_NAME"
fi
usermod -d "/home/$USER_NAME" -s "$USER_SHELL" "$USER_NAME"
# The image grants `ubuntu` passwordless sudo (90-incus): sudo asks for the password
# unless USER_SUDO_NOPASSWD=true, which writes its own file below.
rm -f /etc/sudoers.d/90-incus
echo "$USER_NAME:$USER_PASSWORD" | chpasswd
if is_true "$USER_SUDO"; then
	usermod -aG sudo "$USER_NAME"
	if is_true "$USER_SUDO_NOPASSWD"; then
		echo "$USER_NAME ALL=(ALL:ALL) NOPASSWD: ALL" >"/etc/sudoers.d/$USER_NAME"
		chmod 0440 "/etc/sudoers.d/$USER_NAME"
	fi
fi

# Ubuntu's skeleton .bashrc sets its own `alias ll='ls -alF'`, read after /etc/bash.bashrc.
for f in /etc/skel/.bashrc "/home/$USER_NAME/.bashrc" /root/.bashrc; do
	[ -f "$f" ] && sed -i "s/^\([[:space:]]*\)alias ll=.*/\1alias ll='ls -alFh'/" "$f"
done

say "ssh"
mkdir -p /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/10-template.conf <<EOF
PasswordAuthentication $SSH_PASSWORD_AUTH
PermitRootLogin $SSH_PERMIT_ROOT
EOF
systemctl enable ssh >/dev/null 2>&1
systemctl restart ssh

say "fuse (user_allow_other)"
touch /etc/fuse.conf
sed -i 's/^#user_allow_other/user_allow_other/' /etc/fuse.conf
grep -q '^user_allow_other' /etc/fuse.conf || echo user_allow_other >>/etc/fuse.conf
if getent group fuse >/dev/null; then usermod -aG fuse "$USER_NAME"; fi

if is_true "$INSTALL_RCLONE"; then
	say "rclone"
	case "$(dpkg --print-architecture)" in
		amd64) arch=amd64 ;;
		arm64) arch=arm64 ;;
		armhf) arch=arm-v7 ;;
		*) echo "no rclone build for $(dpkg --print-architecture)" >&2; exit 1 ;;
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
	say "docker ($DOCKER_SOURCE)"
	installed=false
	if [ "$DOCKER_SOURCE" = official ]; then
		install -m 0755 -d /etc/apt/keyrings
		if curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc; then
			chmod a+r /etc/apt/keyrings/docker.asc
			# shellcheck disable=SC1091 # the guest's /etc/os-release
			echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$UBUNTU_CODENAME") stable" >/etc/apt/sources.list.d/docker.list
			if apt-get update -qq && apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
				installed=true
			else
				say "the official Docker repository failed, falling back to the distro packages"
				rm -f /etc/apt/sources.list.d/docker.list
				apt-get update -qq
			fi
		fi
	fi
	if [ "$installed" != true ]; then
		apt-get install -y -qq docker.io docker-compose-v2
	fi
	mkdir -p /etc/docker
	cat >/etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "$DOCKER_LOG_MAX_SIZE", "max-file": "$DOCKER_LOG_MAX_FILE" }
}
EOF
	usermod -aG docker "$USER_NAME"
	systemctl enable docker >/dev/null 2>&1
	systemctl restart docker
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
	--env "INSTALL_DOCKER=$INSTALL_DOCKER" --env "DOCKER_SOURCE=$DOCKER_SOURCE" --env "DOCKER_LOG_MAX_SIZE=$DOCKER_LOG_MAX_SIZE" \
	--env "DOCKER_LOG_MAX_FILE=$DOCKER_LOG_MAX_FILE" --env "INSTALL_NET_TOOLS=$INSTALL_NET_TOOLS" \
	--env "INSTALL_RCLONE=$INSTALL_RCLONE" --env "RCLONE_RELEASE=$RCLONE_RELEASE" \
	--env "EXTRA_PACKAGES=$EXTRA_PACKAGES" \
	-- /root/provision.sh
incus exec "$REF" -- rm -f /root/provision.sh

ip4="$(incus list "${INCUS_REMOTE:+$INCUS_REMOTE:}^$INSTANCE_NAME\$" -c 4 -f csv | tr ',' '\n' | tr -d '"' | awk '/\(eth0\)/ {print $1}')"
log "ready: $REF  ip=${ip4:-?}  user=$USER_NAME  password=$USER_PASSWORD"
log "ssh ${USER_NAME}@${ip4:-<ip>}${INSTANCE_SSH_PUBLISH_PORT:+   (or port $INSTANCE_SSH_PUBLISH_PORT of the incus host)}"
