#!/usr/bin/env bash
#
# The DENY_NETWORK of a dind-env compose, enforced on the host:
#
#   sudo scripts/host-deny.sh COMPOSE          apply
#   sudo scripts/host-deny.sh COMPOSE remove   remove
#
# Reads DENY_NETWORK of service dind and the bridge name of network dind
# (driver_opts com.docker.network.bridge.name) as `docker compose config`
# resolves them, and drops what leaves that bridge towards those networks:
# chain DIND-DENY-<bridge>, jumped to from DOCKER-USER (forwarded: the LAN) and
# INPUT (the host's own addresses). Replies to connections the host starts pass.
# Root in the container cannot remove these rules; run it again after every
# change of DENY_NETWORK and after every boot (not persistent).
#
# It then writes the list to /run/dind-env-deny/<bridge>. With DENY_HOST_CHECK=1
# the container mounts that directory and refuses to start unless the file
# holds its own DENY_NETWORK: /run is empty after a reboot, so the container
# stays down until this script has run.
set -euo pipefail
set -f

die() {
	echo "[host-deny] ERROR: $*" >&2
	exit 1
}

COMPOSE="${1:-}"
[ -n "$COMPOSE" ] || die "usage: sudo $0 COMPOSE [remove]"
[ -f "$COMPOSE" ] || die "$COMPOSE: no such file"
[ "$(id -u)" = 0 ] || die "needs root: sudo $0 $*"

# Its own directory, so a .env next to it counts as it does for `up`.
cfg="$(cd "$(dirname "$COMPOSE")" && docker compose -f "$(basename "$COMPOSE")" config --format json)"
deny="$(jq -r '.services.dind.environment.DENY_NETWORK // ""' <<<"$cfg")"
bridge="$(jq -r '.networks.dind.driver_opts["com.docker.network.bridge.name"] // ""' <<<"$cfg")"
[ -n "$bridge" ] || die "network dind of $COMPOSE has no com.docker.network.bridge.name"
[ "${#bridge}" -le 15 ] || die "bridge name '$bridge' is longer than 15 characters"

CHAIN="DIND-DENY-$bridge"
MARK="/run/dind-env-deny/$bridge"

# Remove first, so apply always starts from nothing. The directory stays: the
# container's mount would keep pointing at a deleted one.
rm -f "$MARK"
for ipt in iptables ip6tables; do
	command -v "$ipt" >/dev/null || continue
	for parent in DOCKER-USER INPUT; do
		while "$ipt" -D "$parent" -i "$bridge" -j "$CHAIN" 2>/dev/null; do :; done
	done
	"$ipt" -F "$CHAIN" 2>/dev/null && "$ipt" -X "$CHAIN"
done
if [ "${2:-}" = remove ]; then
	echo "[host-deny] removed from $bridge"
	exit 0
fi

# Space- or comma-separated, ':' = IPv6, as in entrypoint.claude.sh.
for cidr in ${deny//,/ }; do
	case "$cidr" in
	*:*) ipt=ip6tables ;;
	*) ipt=iptables ;;
	esac
	if ! "$ipt" -n -L "$CHAIN" >/dev/null 2>&1; then
		"$ipt" -N "$CHAIN"
		"$ipt" -A "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
		# dockerd keeps a DOCKER-USER it finds.
		"$ipt" -n -L DOCKER-USER >/dev/null 2>&1 || "$ipt" -N DOCKER-USER
		"$ipt" -I DOCKER-USER -i "$bridge" -j "$CHAIN"
		"$ipt" -I INPUT -i "$bridge" -j "$CHAIN"
	fi
	"$ipt" -A "$CHAIN" -d "$cidr" -j DROP
	echo "[host-deny] $bridge: deny $cidr"
done

# One network per line, sorted: entrypoint.claude.sh compares it the same way.
mkdir -p /run/dind-env-deny
for cidr in ${deny//,/ }; do echo "$cidr"; done | sort -u >"$MARK.tmp"
mv -f "$MARK.tmp" "$MARK"
echo "[host-deny] applied, $MARK written"
