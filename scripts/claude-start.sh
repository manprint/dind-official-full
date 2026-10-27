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

sudo "$here/host-deny.sh" "$compose"
docker compose -f "$compose" up -d
