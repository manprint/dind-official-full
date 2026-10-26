#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088 # single-quoted commands run in the container's shell; ~ in messages is literal
#
# Test of what the claude image adds to the minimal one (entrypoint.claude.sh):
#
#   tests/claude.sh IMAGE
#
# Covers DIND_HOST_LINKS (valid pairs linked, a pair without "=", a relative
# path and a path linked to itself skipped, the image's tool untouched), the
# nvm node paths named by the settings, the plugins' hooks and ~/.claude.json
# linked to /usr/bin/node, ~/.claude.json copied from a read-only host file at
# every start (a host save by rename reaches the container at the next start,
# a non-JSON host file keeps the previous copy), and the DENY_NETWORK rules
# (IPv4 and IPv6, OUTPUT and DOCKER-USER, a packet to a denied address
# dropped). The rest of the image is tests/smoke.sh's.
# Needs a Docker host that allows --privileged; no registry access.
# Everything it creates is named dind-claude-<pid>-* and removed on exit.
set -euo pipefail

IMAGE="${1:?usage: $0 IMAGE}"
ID="dind-claude-$$"
MAIN="$ID-main"
DATA="$ID-data"
HOMEV="$ID-home"
TMPD="$(mktemp -d)"
NVM=/home/u/.nvm/versions/node

cleanup() {
	docker rm -f "$MAIN" >/dev/null 2>&1 || true
	docker volume rm -f "$DATA" "$HOMEV" >/dev/null 2>&1 || true
	rm -rf "$TMPD"
}
trap cleanup EXIT

# As in tests/smoke.sh: under pipefail grep reads a captured string, never a pipe.
ok() { printf 'ok   - %s\n' "$*"; }

fail() {
	printf 'FAIL - %s\n' "$*" >&2
	docker logs --tail 40 "$MAIN" >&2 2>&1 || true
	exit 1
}

in_main() { docker exec "$MAIN" "$@"; }

wait_ready() {
	for _ in $(seq 1 120); do
		if in_main docker version >/dev/null 2>&1; then
			return 0
		fi
		if [ "$(docker inspect -f '{{.State.Running}}' "$MAIN")" != true ]; then
			fail "container exited during startup"
		fi
		sleep 1
	done
	fail "daemon not ready after 120s"
}

# Claude Code saves ~/.claude.json by writing a new file and renaming it over
# the old one: a new inode, which a bind mount of the file itself never sees.
host_save() {
	printf '%s\n' "$1" >"$TMPD/claude.json.new"
	chmod 644 "$TMPD/claude.json.new"
	mv -f "$TMPD/claude.json.new" "$TMPD/claude.json"
}

mkdir -p "$TMPD/claude/plugins/cache/mkt/plug/1.0.0/hooks"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s/v99.1.0/bin/node /x.mjs"}]}]}}\n' "$NVM" >"$TMPD/claude/settings.json"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\\"%s/v98.0.0/bin/node\\" \\"/y.mjs\\""}]}]}}\n' "$NVM" \
	>"$TMPD/claude/plugins/cache/mkt/plug/1.0.0/hooks/hooks.json"
host_save "{\"boot\":1,\"mcpServers\":{\"n\":{\"command\":\"$NVM/v97.0.0/bin/node\"}}}"
chmod -R a+rX "$TMPD"

docker volume create "$DATA" >/dev/null
docker volume create "$HOMEV" >/dev/null
docker run -d --name "$MAIN" --privileged \
	-v "$DATA:/var/lib/docker" -v "$HOMEV:/home/alpine" \
	-v "$TMPD/claude:/home/alpine/.claude" \
	-v "$TMPD/claude.json:/mnt/host/claude.json:ro" \
	-e DIND_HOST_LINKS="/opt/ok/jq=/usr/bin/jq,/usr/bin/node relative=/usr/bin/jq /usr/bin/jq=/usr/bin/jq /opt/ok/none=/usr/bin/missing" \
	-e DENY_NETWORK="192.0.2.0/24,2001:db8::/32" \
	"$IMAGE" >/dev/null
wait_ready
ok "startup"

LOG="$(docker logs "$MAIN" 2>&1)"

# --- DIND_HOST_LINKS
[ "$(in_main readlink /opt/ok/jq)" = /usr/bin/jq ] || fail "valid pair not linked"
in_main /opt/ok/jq --version >/dev/null || fail "linked tool does not run"
ok "DIND_HOST_LINKS: valid pair linked"
grep -qF "'/usr/bin/node' is not HOST=CONTAINER" <<<"$LOG" || fail "pair without = not reported"
grep -qF "'relative=/usr/bin/jq' is not HOST=CONTAINER" <<<"$LOG" || fail "relative pair not reported"
grep -qF "'/usr/bin/jq=/usr/bin/jq' links a path to itself" <<<"$LOG" || fail "self link not reported"
in_main sh -c '[ ! -L /usr/bin/node ] && [ ! -L /usr/bin/jq ]' || fail "an image tool was replaced by a link"
in_main node --version >/dev/null || fail "node broken"
in_main jq --version >/dev/null || fail "jq broken"
ok "DIND_HOST_LINKS: bad pairs skipped, image tools untouched"
grep -qF "/usr/bin/missing missing, /opt/ok/none not linked" <<<"$LOG" || fail "missing target not reported"
in_main sh -c '[ ! -e /opt/ok/none ]' || fail "link to a missing target created"
ok "DIND_HOST_LINKS: missing target skipped"

# --- nvm node paths
for v in v99.1.0 v98.0.0 v97.0.0; do
	[ "$(in_main readlink "$NVM/$v/bin/node")" = /usr/bin/node ] || fail "$NVM/$v/bin/node not linked"
	in_main "$NVM/$v/bin/node" -e 'process.exit(0)' || fail "$NVM/$v/bin/node does not run"
done
ok "nvm node of the settings, the plugins' hooks and ~/.claude.json linked"

# --- ~/.claude.json
[ "$(in_main jq -r .boot /home/alpine/.claude.json)" = 1 ] || fail "~/.claude.json not copied"
[ "$(in_main stat -c '%h %a %U' /home/alpine/.claude.json)" = "1 600 alpine" ] ||
	fail "~/.claude.json is not alpine's own 0600 file: $(in_main stat -c '%h %a %U' /home/alpine/.claude.json)"
grep -qF ' /home/alpine/.claude.json ' <<<"$(in_main cat /proc/self/mountinfo)" && fail "~/.claude.json is a mount"
in_main sh -c 'jq ".written = 1" ~/.claude.json >~/.claude.json.t && mv -f ~/.claude.json.t ~/.claude.json' ||
	fail "~/.claude.json cannot be saved by rename"
ok "~/.claude.json: own copy, saved by rename like Claude Code does"

host_save '{"boot":2}'
docker restart "$MAIN" >/dev/null
wait_ready
[ "$(in_main jq -r .boot /home/alpine/.claude.json)" = 2 ] || fail "host save not copied at the next start"
ok "~/.claude.json: host save by rename copied at the next start"

host_save '{"boot":'
docker restart "$MAIN" >/dev/null
wait_ready
[ "$(in_main jq -r .boot /home/alpine/.claude.json)" = 2 ] || fail "non-JSON host file replaced the copy"
grep -qF "not copied from the host, the previous copy stays" <<<"$(docker logs "$MAIN" 2>&1)" ||
	fail "non-JSON host file not reported"
in_main sh -c '! ls /home/alpine/.claude.json.dind-env-tmp.* 2>/dev/null' || fail "temporary copy left behind"
ok "~/.claude.json: non-JSON host file keeps the previous copy"

# --- DENY_NETWORK, rules set again at every start (the restarts above)
for chain in OUTPUT DOCKER-USER; do
	in_main sudo iptables -C "$chain" -d 192.0.2.0/24 -j DROP || fail "iptables $chain rule missing"
	in_main sudo ip6tables -C "$chain" -d 2001:db8::/32 -j DROP || fail "ip6tables $chain rule missing"
	[ "$(in_main sh -c "sudo iptables -S $chain | grep -c -- '-d 192.0.2.0/24'")" = 1 ] || fail "iptables $chain rule duplicated"
done
in_main nc -z -w 1 192.0.2.1 80 2>/dev/null && fail "denied address reachable"
pkts="$(in_main sh -c 'sudo iptables -L OUTPUT -v -n -x | awk "\$3 == \"DROP\" && \$9 == \"192.0.2.0/24\" {print \$1}"')"
[ "${pkts:-0}" -gt 0 ] || fail "packet to the denied address not dropped by OUTPUT"
ok "DENY_NETWORK: rules in OUTPUT and DOCKER-USER, once each, packet dropped"

echo "all checks passed"
