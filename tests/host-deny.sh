#!/usr/bin/env bash
# shellcheck disable=SC2016 # single-quoted commands run in the container's shell
#
# Test of scripts/host-deny.sh, without touching the real host's firewall:
#
#   tests/host-deny.sh IMAGE
#
# A privileged container of IMAGE plays the host: its own dockerd, a compose
# with a fixed bridge name and an agent container on it, a peer network
# namespace standing for the LAN (forwarded traffic, DOCKER-USER) and a dummy
# address standing for the host's own (INPUT). Covers: the list and the bridge
# read from the compose (defaults, the environment, env-only mode), both paths
# denied while a network outside the list stays reachable, the agent's own
# rules irrelevant (it has none: everything here is on the "host"), replies to
# connections the host starts still let through, status (0 applied, 1 not
# applied or stale), apply idempotent, a shorter list dropping a network,
# IPv6 rules, remove restoring reachability and leaving no chain behind, and
# the refusals (no bridge name, a bad name, no root).
# Needs a Docker host that allows --privileged; no registry access.
# Everything it creates is named dind-hostdeny-<pid>-* and removed on exit.
set -euo pipefail

IMAGE="${1:?usage: $0 IMAGE}"
ID="dind-hostdeny-$$"
HOST="$ID-host"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

cleanup() { docker rm -f -v "$HOST" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# As in tests/smoke.sh: under pipefail grep reads a captured string, never a pipe.
ok() { printf 'ok   - %s\n' "$*"; }

fail() {
	printf 'FAIL - %s\n' "$*" >&2
	exit 1
}

# Root on the "host"; hd = the script under test, run from its checkout.
on_host() { docker exec -u 0 -w /work "$HOST" "$@"; }
hd() { on_host /work/scripts/host-deny.sh "$@"; }

# The agent reaching ADDR:PORT: busybox nc exits 1 when the connect times out.
reach() { on_host docker exec hd-agent-1 /bin/busybox timeout 6 /bin/busybox nc -w 2 "$1" "$2" </dev/null >/dev/null 2>&1; }

drops() { on_host sh -c "iptables -n -v -x -L DIND-DENY-br-hd-test | awk '\$3 == \"DROP\" && \$9 == \"$1\" {print \$1}'"; }

docker run -d --name "$HOST" --privileged -v "$HERE:/work:ro" "$IMAGE" >/dev/null
for _ in $(seq 1 120); do
	on_host docker version >/dev/null 2>&1 && break
	sleep 1
done
on_host docker version >/dev/null 2>&1 || fail "the host's dockerd did not start"

# LAN: a peer namespace with 198.51.100.2 (denied) and 192.0.2.2 (allowed).
# Host's own address: 203.0.113.1 on a dummy (denied). Servers on port 8080.
on_host sh -c '
	set -e
	ip netns add hd-lan
	ip link add hd-v0 type veth peer name hd-v1
	ip link set hd-v1 netns hd-lan
	ip addr add 198.51.100.1/24 dev hd-v0
	ip addr add 192.0.2.1/24 dev hd-v0
	ip link set hd-v0 up
	ip -n hd-lan addr add 198.51.100.2/24 dev hd-v1
	ip -n hd-lan addr add 192.0.2.2/24 dev hd-v1
	ip -n hd-lan link set hd-v1 up
	ip -n hd-lan link set lo up
	ip -n hd-lan route add default via 198.51.100.1
	ip link add hd-d0 type dummy
	ip addr add 203.0.113.1/24 dev hd-d0
	ip link set hd-d0 up
	(ip netns exec hd-lan busybox nc -lk -p 8080 -e /bin/true >/dev/null 2>&1 &)
	(busybox nc -lk -p 8080 -e /bin/true >/dev/null 2>&1 &)
	tar -C / -c bin/busybox "lib/ld-musl-$(uname -m).so.1" | docker import - hd/box >/dev/null
	mkdir -p /hd
	cat >/hd/compose.yml <<EOF
services:
  agent:
    image: hd/box
    command: ["/bin/busybox", "sleep", "1000000"]
    environment:
      DENY_NETWORK: \${DENY_NETWORK:-198.51.100.0/24 203.0.113.0/24 2001:db8::/32}
    networks: [dind]
networks:
  dind:
    driver_opts:
      com.docker.network.bridge.name: \${DIND_BRIDGE_NAME:-br-hd-test}
    ipam:
      config:
        - subnet: 10.250.0.0/24
EOF
	docker compose -p hd -f /hd/compose.yml up -d >/dev/null 2>&1
'
reach 198.51.100.2 8080 || fail "setup: LAN address not reachable before apply"
reach 192.0.2.2 8080 || fail "setup: allowed LAN address not reachable before apply"
reach 203.0.113.1 8080 || fail "setup: host address not reachable before apply"
ok "setup: agent on br-hd-test reaches the LAN and the host"

# --- refusals
out="$(docker exec -u alpine -w /work "$HOST" /work/scripts/host-deny.sh status -f /hd/compose.yml 2>&1)" && fail "ran without root"
grep -qF "needs root" <<<"$out" || fail "no root not reported: $out"
on_host sh -c 'sed "/driver_opts/,/bridge.name/d" /hd/compose.yml >/hd/nobridge.yml'
out="$(hd apply -f /hd/nobridge.yml -s agent 2>&1)" && fail "applied without a bridge name"
grep -qF "has no driver_opts com.docker.network.bridge.name" <<<"$out" || fail "missing bridge name not reported: $out"
out="$(docker exec -u 0 -e DIND_BRIDGE_NAME=a-bridge-name-too-long -e DENY_NETWORK=10.0.0.0/8 "$HOST" /work/scripts/host-deny.sh apply 2>&1)" &&
	fail "applied a 22-character bridge name"
grep -qF "longer than 15 characters" <<<"$out" || fail "long bridge name not reported: $out"
ok "refused: no root, no bridge name in the compose, a name over 15 characters"

# --- status before apply
hd status -f /hd/compose.yml -s agent >/dev/null 2>&1 && fail "status 0 before apply"
ok "status: 1 before apply"

# --- apply from the compose
hd apply -f /hd/compose.yml -s agent >/dev/null
reach 198.51.100.2 8080 && fail "denied LAN address reachable (DOCKER-USER)"
reach 203.0.113.1 8080 && fail "denied host address reachable (INPUT)"
reach 192.0.2.2 8080 || fail "address outside the list blocked"
[ "$(drops 198.51.100.0/24)" -gt 0 ] || fail "no drop counted for the LAN network"
[ "$(drops 203.0.113.0/24)" -gt 0 ] || fail "no drop counted for the host network"
ok "apply: LAN (forwarded) and host (input) denied, the rest reachable"

on_host ip6tables -C DIND-DENY-br-hd-test -d 2001:db8::/32 -m comment --comment dind-env-deny:br-hd-test -j DROP ||
	fail "IPv6 rule missing"
for parent in DOCKER-USER INPUT; do
	on_host ip6tables -C "$parent" -i br-hd-test -m comment --comment dind-env-deny:br-hd-test -j DIND-DENY-br-hd-test ||
		fail "ip6tables jump from $parent missing"
done
ok "apply: IPv6 network in ip6tables, both jumps"

# Replies: a connection the host starts towards the agent is not cut by the DROP
# on the way back (the agent's reply has the host's address as destination).
on_host sh -c 'docker exec -d hd-agent-1 /bin/busybox nc -lk -p 9090 -e /bin/busybox true'
agent_ip="$(on_host docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' hd-agent-1)"
on_host timeout 6 busybox nc -w 2 -s 203.0.113.1 "$agent_ip" 9090 </dev/null >/dev/null 2>&1 ||
	fail "reply to a host-started connection dropped"
ok "apply: replies to connections the host starts let through"

hd status -f /hd/compose.yml -s agent >/dev/null || fail "status not 0 after apply"
ok "status: 0 after apply"

hd apply -f /hd/compose.yml -s agent >/dev/null
for parent in DOCKER-USER INPUT; do
	n="$(on_host sh -c "iptables -S $parent | grep -c -- '-j DIND-DENY-br-hd-test'")"
	[ "$n" = 1 ] || fail "$parent has $n jumps after a second apply"
done
n="$(on_host sh -c "iptables -S DIND-DENY-br-hd-test | grep -c -- '-j DROP'")"
[ "$n" = 2 ] || fail "chain has $n DROP rules after a second apply, want 2"
ok "apply: idempotent (one jump each, one rule per network)"

# --- the compose's list changes: status sees it, apply follows it
out="$(docker exec -u 0 -w /work -e DENY_NETWORK=198.51.100.0/24 "$HOST" /work/scripts/host-deny.sh status -f /hd/compose.yml -s agent 2>&1)" &&
	fail "status 0 with a list other than the one applied"
grep -qF "extra:   203.0.113.0/24" <<<"$out" || fail "stale network not named by status: $out"
docker exec -u 0 -w /work -e DENY_NETWORK=198.51.100.0/24 "$HOST" /work/scripts/host-deny.sh apply -f /hd/compose.yml -s agent >/dev/null
reach 203.0.113.1 8080 || fail "network dropped from the list still denied"
reach 198.51.100.2 8080 && fail "network kept in the list no longer denied"
ok "list changed: status reports the stale network, apply drops it"

# --- env-only mode: no compose file read
docker exec -u 0 -e DENY_NETWORK="203.0.113.0/24,198.51.100.0/24" -e DIND_BRIDGE_NAME=br-hd-test "$HOST" \
	/work/scripts/host-deny.sh apply >/dev/null
reach 203.0.113.1 8080 && fail "env-only apply did not deny"
ok "env-only: DENY_NETWORK and DIND_BRIDGE_NAME without a compose file"

# --- remove
hd remove -f /hd/compose.yml -s agent >/dev/null
reach 198.51.100.2 8080 || fail "LAN address still denied after remove"
reach 203.0.113.1 8080 || fail "host address still denied after remove"
for ipt in iptables ip6tables; do
	grep -qF dind-env-deny <<<"$(on_host "$ipt"-save)" && fail "$ipt rules left after remove"
done
on_host iptables -n -L DOCKER-USER >/dev/null || fail "remove took DOCKER-USER away"
ok "remove: reachable again, no rule or chain left, DOCKER-USER kept"

echo "all checks passed"
