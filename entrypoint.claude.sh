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
host_link() {
	if [ ! -x "$2" ]; then
		echo "[dind-entrypoint] host link: $2 missing, $1 not linked"
		return 0
	fi
	sudo mkdir -p "$(dirname "$1")" && sudo ln -sfn "$2" "$1" &&
		echo "[dind-entrypoint] host link: $1 -> $2" ||
		echo "[dind-entrypoint] host link failed: $1"
}

set -f
for pair in $(printf '%s' "${DIND_HOST_LINKS:-}" | tr ',' ' '); do
	host="${pair%%=*}"
	target="${pair#*=}"
	# A pair without "=" has host = target: ln -sfn would replace the image's
	# tool with a link to itself, and the writable layer keeps it across restarts.
	case "$pair" in
	/*=/*) ;;
	*)
		echo "[dind-entrypoint] host link: '$pair' is not HOST=CONTAINER with absolute paths, skipped"
		continue
		;;
	esac
	if [ "$host" = "$target" ]; then
		echo "[dind-entrypoint] host link: '$pair' links a path to itself, skipped"
		continue
	fi
	host_link "$host" "$target"
done
set +f

# ~/.claude.json: a copy of the host's file, taken at every start. A bind mount
# of the file itself pins its inode, and Claude Code saves it by writing a new
# file and renaming it over the old one: after the host's first save the
# container kept reading, and writing, a deleted file. A torn or non-JSON copy
# keeps the previous one.
claude_json_src="${DIND_CLAUDE_JSON_SRC:-/mnt/host/claude.json}"
if [ -f "$claude_json_src" ]; then
	tmp="/home/alpine/.claude.json.dind-env-tmp.$$"
	if jq -e 'type == "object"' "$claude_json_src" >/dev/null 2>&1 &&
		cp "$claude_json_src" "$tmp" && chmod 600 "$tmp" &&
		mv -f "$tmp" /home/alpine/.claude.json; then
		echo "[dind-entrypoint] ~/.claude.json copied from the host"
	else
		rm -f "$tmp"
		echo "[dind-entrypoint] ~/.claude.json not copied from the host, the previous copy stays"
	fi
fi

# The hooks of the host's plugins (context-mode) name nvm's node by the host's
# version, which changes with every nvm upgrade: link every such path that the
# settings, the plugins' hooks and the MCP config name and that is still missing.
nvm_nodes() {
	for f in /home/alpine/.claude/settings.json /home/alpine/.claude/plugins/cache/*/*/*/hooks/hooks.json /home/alpine/.claude.json; do
		[ -f "$f" ] && grep -ohE '/[^"\\ ]*/\.nvm/versions/node/[^/"\\ ]+/bin/node' "$f"
	done | sort -u
}
for host in $(nvm_nodes); do
	[ -e "$host" ] || host_link "$host" /usr/bin/node
done

exec /usr/local/bin/dev-entrypoint-minimal.sh "$@"
