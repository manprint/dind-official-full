FROM docker:29.7.2-dind

ENV TZ=Europe/Rome \
	LANG=it_IT.UTF-8 \
	LC_ALL=it_IT.UTF-8 \
	LANGUAGE=it_IT:it \
	JAVA_HOME=/usr/lib/jvm/java-21-openjdk \
	PATH="/usr/lib/jvm/java-21-openjdk/bin:${PATH}"

RUN set -eux; \
	apk add --no-cache \
		bash \
		bash-completion \
		bind-tools \
		bridge-utils \
		build-base \
		cargo \
		conntrack-tools \
		coreutils \
		curl \
		direnv \
		ethtool \
		fuse \
		fuse3 \
		g++ \
		gcc \
		git \
		go \
		iftop \
		iperf3 \
		iproute2 \
		iputils \
		just \
		linux-headers \
		lsof \
		make \
		musl-dev \
		musl-locales \
		musl-locales-lang \
		mtr \
		nano \
		net-tools \
		netcat-openbsd \
		nftables \
		ngrep \
		nmap \
		nodejs \
		npm \
		openjdk21-jdk \
		py3-pip \
		python3 \
		rust \
		socat \
		strace \
		sudo \
		tcpdump \
		traceroute \
		tree \
		tzdata \
		unzip; \
	ln -sf /usr/share/zoneinfo/Europe/Rome /etc/localtime; \
	echo "Europe/Rome" > /etc/timezone; \
	for f in /etc/fuse.conf /etc/fuse3.conf; do \
		if [ -f "$f" ]; then \
			sed -i 's/^#user_allow_other/user_allow_other/' "$f"; \
			grep -q '^user_allow_other' "$f" || echo 'user_allow_other' >> "$f"; \
		else \
			printf 'user_allow_other\n' > "$f"; \
		fi; \
	done; \
	printf 'export TZ=Europe/Rome\nexport LANG=it_IT.UTF-8\nexport LC_ALL=it_IT.UTF-8\nexport LANGUAGE=it_IT:it\n' > /etc/profile.d/10locale.sh; \
	printf 'command -v direnv >/dev/null 2>&1 && eval "$(direnv hook bash)"\n' > /etc/profile.d/20direnv.sh; \
	npm install -g typescript @angular/cli pm2 pm2-logrotate; \
	apkArch="$(apk --print-arch)"; \
	case "$apkArch" in \
		x86_64) rcloneArch=amd64 ;; \
		aarch64) rcloneArch=arm64 ;; \
		armv7) rcloneArch=arm-v7 ;; \
		*) echo >&2 "unsupported arch for rclone: $apkArch"; exit 1 ;; \
	esac; \
	wget -O /tmp/rclone.zip "https://downloads.rclone.org/rclone-current-linux-${rcloneArch}.zip"; \
	unzip -o /tmp/rclone.zip -d /tmp; \
	install -m 0755 /tmp/rclone-*-linux-${rcloneArch}/rclone /usr/local/bin/rclone; \
	rm -rf /tmp/rclone.zip /tmp/rclone-*-linux-${rcloneArch}; \
	rclone version; \
	addgroup -g 1000 alpine; \
	adduser -D -u 1000 -G alpine -h /home/alpine -s /bin/bash alpine; \
	if ! getent group docker >/dev/null; then addgroup -S docker; fi; \
	addgroup alpine docker; \
	if getent group fuse >/dev/null; then addgroup alpine fuse; fi; \
	printf 'Defaults:alpine !env_reset\nDefaults:alpine secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"\nalpine ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/alpine; \
	chmod 0440 /etc/sudoers.d/alpine; \
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
