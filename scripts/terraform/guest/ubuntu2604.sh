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
