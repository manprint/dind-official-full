FROM docker:29.8.2-dind

# "current" resolves to the newest rclone at build time; CI resolves it once
# and passes the same version to every platform build. Not RCLONE_VERSION:
# rclone reads RCLONE_* variables as flag defaults and takes that one for
# --version, so `rclone version` below would fail.
ARG DIND_RCLONE_VERSION=current

ENV TZ=Europe/Rome \
	LANG=it_IT.UTF-8 \
	LC_ALL=it_IT.UTF-8 \
	LANGUAGE=it_IT:it \
	JAVA_HOME=/usr/lib/jvm/java-21-openjdk \
	VIRTUAL_ENV=/opt/venv \
	PATH="/opt/venv/bin:/usr/lib/jvm/java-21-openjdk/bin:${PATH}"

# docker-init (tini) is not PID 1 here, the entrypoint is: as a subreaper it
# still reaps dockerd's orphans, and it stops warning that it cannot.
ENV TINI_SUBREAPER=1

RUN set -eux; \
	apk upgrade --no-cache; \
	apk add --no-cache \
		bash \
		bash-completion \
		bat \
		bind-tools \
		bridge-utils \
		build-base \
		cargo \
		conntrack-tools \
		coreutils \
		curl \
		direnv \
		ethtool \
		fd \
		flock \
		fzf \
		fuse \
		fuse3 \
		github-cli \
		git \
		go \
		iftop \
		iperf3 \
		iproute2 \
		iputils \
		jq \
		just \
		linux-headers \
		lsof \
		musl-locales \
		musl-locales-lang \
		mtr \
		nano \
		ncurses \
		net-tools \
		netcat-openbsd \
		nftables \
		ngrep \
		nmap \
		nodejs \
		npm \
		openjdk21-jdk \
		py3-pip \
		py3-virtualenv \
		python3 \
		python3-dev \
		ripgrep \
		rust \
		shellcheck \
		shfmt \
		socat \
		strace \
		sudo \
		tar \
		tcpdump \
		tmux \
		traceroute \
		tree \
		tzdata \
		unzip \
		yq; \
	python3 -m venv /opt/venv; \
	/opt/venv/bin/pip install --upgrade pip setuptools wheel; \
	ln -sf /usr/share/zoneinfo/Europe/Rome /etc/localtime; \
	echo "Europe/Rome" > /etc/timezone; \
	touch /etc/fuse.conf; \
	sed -i 's/^#user_allow_other/user_allow_other/' /etc/fuse.conf; \
	grep -q '^user_allow_other' /etc/fuse.conf || echo 'user_allow_other' >> /etc/fuse.conf; \
	printf 'export TZ=Europe/Rome\nexport LANG=it_IT.UTF-8\nexport LC_ALL=it_IT.UTF-8\nexport LANGUAGE=it_IT:it\n' > /etc/profile.d/10locale.sh; \
	printf '# /etc/profile resets PATH: restore the image one (venv, JDK) for login shells.\nexport PATH="%s"\n' "$PATH" > /etc/profile.d/00dind-path.sh; \
	printf 'if [ -n "${BASH_VERSION:-}" ] && command -v direnv >/dev/null 2>&1; then eval "$(direnv hook bash)"; fi\n' > /etc/profile.d/20direnv.sh; \
	npm install -g prettier eslint typescript @angular/cli pm2; \
	apkArch="$(apk --print-arch)"; \
	case "$apkArch" in \
		x86_64) rcloneArch=amd64 ;; \
		aarch64) rcloneArch=arm64 ;; \
		armv7) rcloneArch=arm-v7 ;; \
		*) echo >&2 "unsupported arch for rclone: $apkArch"; exit 1 ;; \
	esac; \
	rcloneVersion="$DIND_RCLONE_VERSION"; \
	if [ "$rcloneVersion" = current ]; then \
		rcloneVersion="$(wget -qO- https://downloads.rclone.org/version.txt | awk '{print $2}')"; \
	fi; \
	rcloneDir="rclone-${rcloneVersion}-linux-${rcloneArch}"; \
	wget -O "/tmp/${rcloneDir}.zip" "https://downloads.rclone.org/${rcloneVersion}/${rcloneDir}.zip"; \
	wget -O /tmp/rclone.sha256sums "https://downloads.rclone.org/${rcloneVersion}/SHA256SUMS"; \
	(cd /tmp && grep " ${rcloneDir}\.zip\$" rclone.sha256sums | sha256sum -c -); \
	unzip -o "/tmp/${rcloneDir}.zip" -d /tmp; \
	install -m 0755 "/tmp/${rcloneDir}/rclone" /usr/local/bin/rclone; \
	rm -rf "/tmp/${rcloneDir}.zip" "/tmp/${rcloneDir}" /tmp/rclone.sha256sums; \
	rclone version; \
	addgroup -g 1000 alpine; \
	adduser -D -u 1000 -G alpine -h /home/alpine -s /bin/bash alpine; \
	if ! getent group docker >/dev/null; then addgroup -S docker; fi; \
	addgroup alpine docker; \
	if getent group fuse >/dev/null; then addgroup alpine fuse; fi; \
	chown -R alpine:alpine /opt/venv; \
	printf '%s\n' \
		'# !env_reset: the entrypoint hands DOCKER_TLS_CERTDIR & co. to dockerd-entrypoint.sh.' \
		'# always_set_home: with the environment kept, root would inherit HOME=/home/alpine.' \
		'Defaults:alpine !env_reset' \
		'Defaults:alpine always_set_home' \
		'Defaults:alpine secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' \
		'alpine ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/alpine; \
	chmod 0440 /etc/sudoers.d/alpine; \
	visudo -cf /etc/sudoers.d/alpine; \
	sudo -u alpine -H pm2 install pm2-logrotate; \
	sudo -u alpine -H pm2 set pm2-logrotate:max_size 10M; \
	sudo -u alpine -H pm2 set pm2-logrotate:retain 7; \
	sudo -u alpine -H pm2 set pm2-logrotate:compress true; \
	sudo -u alpine -H pm2 save --force; \
	sudo -u alpine -H pm2 kill; \
	rm -f /home/alpine/.pm2/*.sock /home/alpine/.pm2/pm2.pid; \
	mkdir -p /etc/skel; \
	cp -a /home/alpine/.pm2 /etc/skel/.pm2; \
	rm -rf /root/.npm /root/.pm2 /tmp/*

COPY bashrc /etc/skel/.bashrc
COPY bash_aliases /etc/skel/.bash_aliases
COPY profile /etc/skel/.profile
COPY entrypoint.sh /usr/local/bin/dev-entrypoint.sh

RUN set -eux; \
	chmod +x /usr/local/bin/dev-entrypoint.sh; \
	install -m 0644 /etc/skel/.bashrc /root/.bashrc; \
	install -m 0644 /etc/skel/.bash_aliases /root/.bash_aliases; \
	install -m 0644 /etc/skel/.profile /root/.profile; \
	ln -sfn .profile /root/.bash_profile; \
	install -m 0644 /etc/skel/.bashrc /home/alpine/.bashrc; \
	install -m 0644 /etc/skel/.bash_aliases /home/alpine/.bash_aliases; \
	install -m 0644 /etc/skel/.profile /home/alpine/.profile; \
	ln -sfn .profile /home/alpine/.bash_profile; \
	chown alpine:alpine /home/alpine/.bashrc /home/alpine/.bash_aliases /home/alpine/.profile /home/alpine/.bash_profile

VOLUME ["/var/lib/docker", "/home/alpine"]
EXPOSE 2375 2376

USER alpine
WORKDIR /home/alpine
ENTRYPOINT ["/usr/local/bin/dev-entrypoint.sh"]
CMD []
