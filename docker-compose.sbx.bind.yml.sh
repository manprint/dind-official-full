#!/bin/bash
#
# Prepare the host for docker-compose.sbx.bind.yml, then start it as usual:
#
#   ./docker-compose.sbx.bind.yml.sh [COMPOSE]
#   docker compose -f docker-compose.sbx.bind.yml up -d
#
# COMPOSE defaults to docker-compose.sbx.bind.yml next to this script. The
# paths come from `docker compose config`, so SBX_DATA, SBX_SECRETS_DIR and
# SBX_WORKSPACE are read the way compose reads them: environment, then the
# .env next to the compose, then the compose defaults, relative paths from the
# compose's directory. Every bind-mount source is created as the calling user
# (left to Docker they would be root's), and SBX_SECRETS_DIR gets the keyring
# password. Safe to run again: existing directories are kept, and an existing
# keyring_pass is never replaced (a new one would no longer open the keyring).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
compose="${1:-$here/docker-compose.sbx.bind.yml}"

die() { echo "error: $*" >&2; exit 1; }

[ -f "$compose" ] || die "compose file not found: $compose"
docker compose version >/dev/null 2>&1 || die "docker compose (v2) not found"
# JSON, one key per line: the YAML output folds long paths over several lines.
config="$(docker compose -f "$compose" config --format json)" || die "docker compose config failed for $compose"

# One "source<TAB>target" line per bind mount, and the container name.
mounts="$(awk '
	function val(s) {
		sub(/^[^:]*: "/, "", s); sub(/",?$/, "", s)
		gsub(/\\"/, "\"", s); gsub(/\\u0026/, "\\&", s)
		gsub(/\\u003c/, "<", s); gsub(/\\u003e/, ">", s); gsub(/\\\\/, "\\", s)
		return s
	}
	/^ *"type": / { bind = ($0 ~ /"bind"/); src = ""; next }
	bind && /^ *"source": / { src = val($0); next }
	bind && /^ *"target": / { print src "\t" val($0); bind = 0 }
' <<<"$config")"
[ -n "$mounts" ] || die "no bind mounts in $compose"
name="$(sed -n 's/^ *"container_name": "\(.*\)",*$/\1/p' <<<"$config" | head -n 1)"

secrets=""
while IFS=$'\t' read -r src dst; do
	if [ -d "$src" ]; then
		echo "ok       $src"
	elif [ -e "$src" ]; then
		die "$src exists and is not a directory (mounted on $dst)"
	else
		mkdir -p "$src"
		echo "created  $src"
	fi
	if [ "$dst" = /run/secrets/sbx ]; then
		secrets="$src"
	fi
done <<<"$mounts"

if [ -n "$secrets" ]; then
	pass="$secrets/keyring_pass"
	if [ -s "$pass" ]; then
		echo "kept     $pass"
	else
		[ -w "$secrets" ] || die "$secrets is not writable (created by Docker as root?): sudo chown $(id -u):$(id -g) $secrets"
		chmod 700 "$secrets"
		(umask 077 && head -c 32 /dev/urandom | base64 | tr -d '\n' >"$pass")
		echo "created  $pass"
	fi
fi

[ -c /dev/kvm ] || echo "warning: no /dev/kvm on this host: sbx cannot start sandboxes" >&2

echo
echo "next: docker compose -f $compose up -d"
echo "      docker exec -it ${name:-<container>} sbx login"
