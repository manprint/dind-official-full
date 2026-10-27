#!/usr/bin/env bash
#
# The DENY_NETWORK of a dind-env container, enforced on the host.
#
#   sudo scripts/host-deny.sh apply  [-f COMPOSE] [-s SERVICE] [-n NETWORK]
#   sudo scripts/host-deny.sh remove [-f COMPOSE] [-s SERVICE] [-n NETWORK]
#   sudo scripts/host-deny.sh status [-f COMPOSE] [-s SERVICE] [-n NETWORK]
#
# The rules entrypoint.claude.sh sets inside the container live in the
# container's own network namespace, so root in there (passwordless sudo, or an
# inner `docker run --privileged --network host`) can remove them. These live
# on the host, matched on the compose network's bridge: everything the
# container and its nested containers send leaves through it, whatever the
# container does to its own addresses, routes and rules. With a runtime that
# keeps root in the container away from the host (sysbox-runc), they are out of
# its reach.
#
# The list and the bridge come from the compose file, so the host copies the
# compose's rules: DENY_NETWORK of SERVICE (default dind) and the
# com.docker.network.bridge.name driver option of NETWORK (default dind), as
# `docker compose config` resolves them (defaults, .env, the environment).
# DENY_NETWORK and DIND_BRIDGE_NAME in the environment override the file; with
# both set, no compose file is read. Default file: compose-claude.yml next to
# this script's directory, else ./compose.yml.
#
# One chain per bridge, DIND-DENY-<bridge> (iptables and ip6tables), holding
# a RETURN for replies (ESTABLISHED,RELATED: only what the container starts is
# denied) and one DROP per network, reached from DOCKER-USER (forwarded
# traffic: the LAN, other hosts) and INPUT (the host's own addresses), both
# matched on -i <bridge>. A bridge that does not exist yet matches nothing, so
# apply can run before the container. apply rebuilds the chain from scratch
# and is idempotent; remove takes away the chain and its two jumps only;
# status exits 0 when the rules in place are the ones the compose names.
#
# Not persistent: the host's firewall starts empty at boot. Run apply from a
# unit ordered after docker.service (scripts/host-deny.service).
set -euo pipefail

usage() {
	sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 2
}

log() { printf '[host-deny] %s\n' "$*"; }
die() {
	printf '[host-deny] ERROR: %s\n' "$*" >&2
	exit 1
}

ACTION="${1:-}"
case "$ACTION" in
apply | remove | status) shift ;;
*) usage ;;
esac

COMPOSE=""
SERVICE=dind
NETWORK=dind
while getopts 'f:s:n:h' opt; do
	case "$opt" in
	f) COMPOSE="$OPTARG" ;;
	s) SERVICE="$OPTARG" ;;
	n) NETWORK="$OPTARG" ;;
	*) usage ;;
	esac
done

[ "$(id -u)" = 0 ] || die "needs root (iptables): sudo $0 $ACTION ..."

deny="${DENY_NETWORK-}"
bridge="${DIND_BRIDGE_NAME-}"
if [ -z "${DENY_NETWORK+x}" ] || [ -z "${DIND_BRIDGE_NAME+x}" ]; then
	if [ -z "$COMPOSE" ]; then
		here="$(cd "$(dirname "$0")/.." && pwd)"
		if [ -f "$here/compose-claude.yml" ]; then
			COMPOSE="$here/compose-claude.yml"
		elif [ -f compose.yml ]; then
			COMPOSE=compose.yml
		else
			die "no compose file: pass -f COMPOSE, or set DENY_NETWORK and DIND_BRIDGE_NAME"
		fi
	fi
	[ -f "$COMPOSE" ] || die "$COMPOSE: no such file"
	command -v jq >/dev/null || die "jq is needed to read $COMPOSE"
	# --no-interpolate would leave ${VAR:-default} unresolved: let compose resolve it.
	# Its own directory, so a .env next to it counts as it does for `up`.
	cfg="$(cd "$(dirname "$COMPOSE")" && docker compose -f "$(basename "$COMPOSE")" config --format json)" ||
		die "docker compose config failed on $COMPOSE"
	if [ -z "${DENY_NETWORK+x}" ]; then
		deny="$(jq -r --arg s "$SERVICE" '.services[$s].environment.DENY_NETWORK // ""' <<<"$cfg")"
	fi
	if [ -z "${DIND_BRIDGE_NAME+x}" ]; then
		bridge="$(jq -r --arg n "$NETWORK" '.networks[$n].driver_opts["com.docker.network.bridge.name"] // ""' <<<"$cfg")"
	fi
	[ -n "$bridge" ] || die "network '$NETWORK' of $COMPOSE has no driver_opts com.docker.network.bridge.name: without a fixed bridge name there is nothing to match"
fi

# Linux interface names: at most 15 bytes, no '/', no whitespace.
case "$bridge" in
'' | */* | *[[:space:]]*) die "bad bridge name '$bridge'" ;;
esac
[ "${#bridge}" -le 15 ] || die "bridge name '$bridge' is longer than 15 characters"
CHAIN="DIND-DENY-$bridge"
TAG="dind-env-deny:$bridge"

# Same splitting as entrypoint.claude.sh: space- or comma-separated, ':' = IPv6.
v4=()
v6=()
for cidr in ${deny//,/ }; do
	case "$cidr" in
	*:*) v6+=("$cidr") ;;
	*) v4+=("$cidr") ;;
	esac
done

JUMP=(-i "$bridge" -m comment --comment "$TAG" -j "$CHAIN")

# remove_family IPT: the two jumps (every copy) and the chain.
remove_family() {
	local ipt="$1" parent
	for parent in DOCKER-USER INPUT; do
		while "$ipt" -C "$parent" "${JUMP[@]}" 2>/dev/null; do
			"$ipt" -D "$parent" "${JUMP[@]}"
		done
	done
	if "$ipt" -n -L "$CHAIN" >/dev/null 2>&1; then
		"$ipt" -F "$CHAIN"
		"$ipt" -X "$CHAIN"
	fi
}

# apply_family IPT CIDR...: the chain rebuilt with these networks, the jumps
# once each at the top of DOCKER-USER and INPUT. No networks: removed.
apply_family() {
	local ipt="$1" cidr parent
	shift
	if [ "$#" = 0 ]; then
		remove_family "$ipt"
		return
	fi
	# dockerd creates DOCKER-USER only when missing and leaves it alone, so a
	# chain made before docker starts is the one it uses.
	"$ipt" -n -L DOCKER-USER >/dev/null 2>&1 || "$ipt" -N DOCKER-USER
	"$ipt" -n -L "$CHAIN" >/dev/null 2>&1 || "$ipt" -N "$CHAIN"
	"$ipt" -F "$CHAIN"
	"$ipt" -A "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$TAG" -j RETURN
	for cidr in "$@"; do
		"$ipt" -A "$CHAIN" -d "$cidr" -m comment --comment "$TAG" -j DROP ||
			die "$ipt refused '$cidr' (chain $CHAIN left with the networks before it)"
	done
	for parent in DOCKER-USER INPUT; do
		"$ipt" -C "$parent" "${JUMP[@]}" 2>/dev/null || "$ipt" -I "$parent" 1 "${JUMP[@]}"
	done
}

# status_family IPT CIDR...: 0 when chain and jumps hold exactly these networks.
status_family() {
	local ipt="$1" parent want have
	shift
	if [ "$#" = 0 ]; then
		if "$ipt" -n -L "$CHAIN" >/dev/null 2>&1; then
			log "$ipt: $CHAIN present, the compose names no network for it"
			return 1
		fi
		log "$ipt: nothing to deny, nothing in place"
		return 0
	fi
	if ! "$ipt" -n -L "$CHAIN" >/dev/null 2>&1; then
		log "$ipt: $CHAIN missing (not applied)"
		return 1
	fi
	for parent in DOCKER-USER INPUT; do
		if ! "$ipt" -C "$parent" "${JUMP[@]}" 2>/dev/null; then
			log "$ipt: jump from $parent to $CHAIN missing"
			return 1
		fi
	done
	want="$(printf '%s\n' "$@" | sort)"
	have="$("$ipt" -S "$CHAIN" | awk '$1 == "-A" && / -j DROP/ { for (i = 1; i < NF; i++) if ($i == "-d") print $(i + 1) }' |
		sed 's#/128$##; s#/32$##' | sort)"
	want="$(sed 's#/128$##; s#/32$##' <<<"$want")"
	if [ "$want" != "$have" ]; then
		log "$ipt: $CHAIN holds other networks than the compose:"
		diff <(printf '%s\n' "$want") <(printf '%s\n' "$have") | sed -n 's/^</  missing:/p; s/^>/  extra:  /p'
		return 1
	fi
	"$ipt" -n -v -x -L "$CHAIN" | sed 's/^/  /'
	return 0
}

case "$ACTION" in
apply)
	[ "$((${#v4[@]} + ${#v6[@]}))" -gt 0 ] || log "DENY_NETWORK is empty: removing what is in place for $bridge"
	apply_family iptables "${v4[@]}"
	if command -v ip6tables >/dev/null; then
		apply_family ip6tables "${v6[@]}"
	elif [ "${#v6[@]}" -gt 0 ]; then
		die "ip6tables missing: the IPv6 networks (${v6[*]}) cannot be denied"
	fi
	log "applied on $bridge: ${v4[*]} ${v6[*]}"
	;;
remove)
	remove_family iptables
	command -v ip6tables >/dev/null && remove_family ip6tables
	log "removed from $bridge"
	;;
status)
	rc=0
	log "bridge $bridge, chain $CHAIN, networks: ${v4[*]} ${v6[*]}"
	status_family iptables "${v4[@]}" || rc=1
	if command -v ip6tables >/dev/null; then
		status_family ip6tables "${v6[@]}" || rc=1
	fi
	exit "$rc"
	;;
esac
