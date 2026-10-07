#!/bin/sh
set -eu
say() { echo "[guest] $*"; }
is_true() { [ "$1" = true ] || [ "$1" = yes ] || [ "$1" = 1 ]; }

say "packages"
# The language pack of LOCALE (it_IT.UTF-8: glibc-langpack-it); C.UTF-8 is built in.
langpack=""
case "$LOCALE" in *_*) langpack="glibc-langpack-${LOCALE%%_*}" ;; esac
pkgs="sudo openssh-server openssh-clients tzdata $langpack kbd passwd shadow-utils which procps-ng findutils
	curl wget ca-certificates openssl git vim-enhanced nano rsync unzip jq htop lsof fuse3 bash-completion $EXTRA_PACKAGES"
if is_true "$INSTALL_NET_TOOLS"; then
	pkgs="$pkgs iproute iputils traceroute mtr tcpdump nmap nmap-ncat socat iperf3 bind-utils ethtool net-tools conntrack-tools iptables-nft nftables"
fi
# shellcheck disable=SC2086 # one argument per package
dnf install -y -q --setopt=install_weak_deps=False $pkgs

say "hostname, timezone, locale, keyboard"
hostname "$INSTANCE_NAME" 2>/dev/null || true
echo "$INSTANCE_NAME" >/etc/hostname
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
echo "$TIMEZONE" >/etc/timezone
printf 'LANG=%s\nLC_ALL=%s\nLANGUAGE=%s\n' "$LOCALE" "$LOCALE" "${LOCALE%%.*}:${LOCALE%%_*}" >/etc/locale.conf
# zz-: Fedora's lang.sh (earlier in the glob) unsets LC_ALL.
cat >/etc/profile.d/zz-locale.sh <<EOF
export LANG=$LOCALE
export LC_ALL=$LOCALE
export LANGUAGE=${LOCALE%%.*}:${LOCALE%%_*}
EOF
chmod 0644 /etc/profile.d/zz-locale.sh
mkdir -p /etc/default
cat >/etc/default/keyboard <<EOF
XKBMODEL="pc105"
XKBLAYOUT="$KEYMAP"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF
echo "KEYMAP=$KEYMAP" >/etc/vconsole.conf

say "aliases (every user)"
# Last in the glob: Fedora's colorls.sh sets its own `ll`. /etc/profile.d is read by
# login shells and, through /etc/bashrc, by every interactive bash.
printf '%s\n' "alias ll='ls -alFh'" >/etc/profile.d/zz-aliases.sh
chmod 0644 /etc/profile.d/zz-aliases.sh

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
echo "$USER_NAME:$USER_PASSWORD" | chpasswd
if is_true "$USER_SUDO"; then
	usermod -aG wheel "$USER_NAME"
	if is_true "$USER_SUDO_NOPASSWD"; then
		echo "$USER_NAME ALL=(ALL:ALL) NOPASSWD: ALL" >"/etc/sudoers.d/$USER_NAME"
		chmod 0440 "/etc/sudoers.d/$USER_NAME"
	fi
fi

say "ssh"
mkdir -p /etc/ssh/sshd_config.d
# 10- sorts before Fedora's 50-redhat.conf: the first value of a keyword wins.
cat >/etc/ssh/sshd_config.d/10-template.conf <<EOF
PasswordAuthentication $SSH_PASSWORD_AUTH
PermitRootLogin $SSH_PERMIT_ROOT
EOF
systemctl enable sshd >/dev/null 2>&1
systemctl restart sshd

say "fuse (user_allow_other)"
touch /etc/fuse.conf
sed -i 's/^#user_allow_other/user_allow_other/' /etc/fuse.conf
grep -q '^user_allow_other' /etc/fuse.conf || echo user_allow_other >>/etc/fuse.conf
if getent group fuse >/dev/null; then usermod -aG fuse "$USER_NAME"; fi

if is_true "$INSTALL_RCLONE"; then
	say "rclone"
	case "$(uname -m)" in
		x86_64) arch=amd64 ;;
		aarch64) arch=arm64 ;;
		armv7l) arch=arm-v7 ;;
		*) echo "no rclone build for $(uname -m)" >&2; exit 1 ;;
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
		if curl -fsSL https://download.docker.com/linux/fedora/docker-ce.repo -o /etc/yum.repos.d/docker-ce.repo; then
			if dnf install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
				installed=true
			else
				say "the official Docker repository failed, falling back to the distro packages"
				rm -f /etc/yum.repos.d/docker-ce.repo
			fi
		fi
	fi
	if [ "$installed" != true ]; then
		dnf install -y -q moby-engine docker-compose
	fi
	mkdir -p /etc/docker
	cat >/etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "$DOCKER_LOG_MAX_SIZE", "max-file": "$DOCKER_LOG_MAX_FILE" }
}
EOF
	getent group docker >/dev/null || groupadd -r docker
	usermod -aG docker "$USER_NAME"
	systemctl enable docker >/dev/null 2>&1
	systemctl restart docker
	i=0
	while [ "$i" -lt 30 ] && ! docker info >/dev/null 2>&1; do i=$((i + 1)); sleep 1; done
	docker version --format 'docker {{.Server.Version}}'
	docker compose version
fi
say "done"
