#!/bin/sh
# Entrypoint of the Claude image: entrypoint.minimal.sh behind a deny list.
# DENY_NETWORK="192.168.1.0/24 100.100.0.0/16" (or comma-separated) names
# the networks this container and the containers nested in it may not reach.
# The rules go into this container's own network namespace only, the host is
# not touched:
#   OUTPUT       the container's own traffic (shell, claude, gh, aws)
#   DOCKER-USER  the nested containers' traffic, which dockerd forwards through
#                this container. Matched on destination: their source is still
#                the inner address when the packet crosses this chain.
# dockerd leaves DOCKER-USER alone (it creates it only when missing, and adds
# its own jump from FORWARD). The network namespace is new at every start, so
# the rules are set at every start, before dockerd. A rule that cannot be set
# stops the container: a deny list that fails open is no deny list.
set -eu

deny_rule() {
	case "$1" in
	*:*) ipt=ip6tables ;;
	*) ipt=iptables ;;
	esac
	sudo "$ipt" -N DOCKER-USER 2>/dev/null || true
	for chain in OUTPUT DOCKER-USER; do
		sudo "$ipt" -C "$chain" -d "$1" -j DROP 2>/dev/null ||
			sudo "$ipt" -I "$chain" -d "$1" -j DROP
	done
}

# Same splitting as DIND_DNS in entrypoint.minimal.sh: space- or comma-separated.
set -f
for cidr in $(printf '%s' "${DENY_NETWORK:-}" | tr ',' ' '); do
	deny_rule "$cidr"
	echo "[dind-entrypoint] egress deny: $cidr"
done
set +f

# DIND_HOST_LINKS="HOST=CONTAINER ..." (or comma-separated): the host's settings
# and MCP config name some tools by their host path. Each HOST becomes a symlink
# to the image's CONTAINER, so the same settings work in here. Link only tools
# of the image: a HOST inside a mounted directory would be written on the host.
set -f
for pair in $(printf '%s' "${DIND_HOST_LINKS:-}" | tr ',' ' '); do
	host="${pair%%=*}"
	target="${pair#*=}"
	if [ ! -x "$target" ]; then
		echo "[dind-entrypoint] host link: $target missing, $host not linked"
		continue
	fi
	sudo mkdir -p "$(dirname "$host")" && sudo ln -sfn "$target" "$host" &&
		echo "[dind-entrypoint] host link: $host -> $target" ||
		echo "[dind-entrypoint] host link failed: $host"
done
set +f

exec /usr/local/bin/dev-entrypoint-minimal.sh "$@"
