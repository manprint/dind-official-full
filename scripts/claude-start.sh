#!/bin/bash
#
# Start the claude variant behind the host's deny list:
#
#   ./claude-start.sh [COMPOSE]
#
# COMPOSE defaults to compose-claude.yml next to this script, else in its
# parent directory (the repository's layout). host-deny.sh must sit next to
# this script. Run it after every boot: the host's rules do not survive one,
# and with DENY_HOST_CHECK=1 the container does not start without them.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

compose="${1:-}"
if [ -z "$compose" ]; then
	compose="$here/compose-claude.yml"
	[ -f "$compose" ] || compose="$here/../compose-claude.yml"
fi

# sudo resets the environment: without these, host-deny.sh would read the
# compose's defaults while `up` below reads the caller's values, and the
# container would refuse to start (DENY_HOST_CHECK) or run on another bridge.
vars=()
for v in DENY_NETWORK DIND_BRIDGE_NAME; do
	[ -z "${!v+set}" ] || vars+=("$v=${!v}")
done
# Plain sudo when nothing is set: a sudoers entry for host-deny.sh alone still works.
cmd=("$here/host-deny.sh" "$compose")
[ "${#vars[@]}" -eq 0 ] || cmd=(env "${vars[@]}" "${cmd[@]}")
sudo "${cmd[@]}"
docker compose -f "$compose" up -d
