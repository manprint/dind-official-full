#!/bin/bash
#
# Stop the claude variant, then take the host's deny list away:
#
#   ./claude-stop.sh [COMPOSE]
#
# Same COMPOSE default as claude-start.sh. The container goes first: removed
# the other way round, it would run for a moment with no rule on the host.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

compose="${1:-}"
if [ -z "$compose" ]; then
	compose="$here/compose-claude.yml"
	[ -f "$compose" ] || compose="$here/../compose-claude.yml"
fi

docker compose -f "$compose" down
# As in claude-start.sh: the caller's bridge name, which sudo would drop.
vars=()
for v in DENY_NETWORK DIND_BRIDGE_NAME; do
	[ -z "${!v+set}" ] || vars+=("$v=${!v}")
done
# Plain sudo when nothing is set: a sudoers entry for host-deny.sh alone still works.
cmd=("$here/host-deny.sh" "$compose" remove)
[ "${#vars[@]}" -eq 0 ] || cmd=(env "${vars[@]}" "${cmd[@]}")
sudo "${cmd[@]}"
