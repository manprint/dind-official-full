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
