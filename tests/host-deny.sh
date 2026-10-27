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
# read from the compose (defaults and the environment), both paths denied
# while a network outside the list stays reachable, replies to connections the
# host starts still let through, the list written to /run/dind-env-deny/<bridge>
# for DENY_HOST_CHECK, apply idempotent, a shorter list dropping a network,
# IPv6 rules, remove restoring reachability and leaving no chain or list behind,
# and the refusals (no bridge name, a name over 15 characters, no root).
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
reach() { on_host docker exec hd-dind-1 /bin/busybox timeout 6 /bin/busybox nc -w 2 "$1" "$2" </dev/null >/dev/null 2>&1; }

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
  dind:
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
out="$(docker exec -u alpine -w /work "$HOST" /work/scripts/host-deny.sh /hd/compose.yml 2>&1)" && fail "ran without root"
grep -qF "needs root" <<<"$out" || fail "no root not reported: $out"
on_host sh -c 'sed "/driver_opts/,/bridge.name/d" /hd/compose.yml >/hd/nobridge.yml'
out="$(hd /hd/nobridge.yml 2>&1)" && fail "applied without a bridge name"
grep -qF "has no com.docker.network.bridge.name" <<<"$out" || fail "missing bridge name not reported: $out"
out="$(docker exec -u 0 -e DIND_BRIDGE_NAME=a-bridge-name-too-long "$HOST" /work/scripts/host-deny.sh /hd/compose.yml 2>&1)" &&
	fail "applied a 22-character bridge name"
grep -qF "longer than 15 characters" <<<"$out" || fail "long bridge name not reported: $out"
ok "refused: no root, no bridge name in the compose, a name over 15 characters"

# --- apply
hd /hd/compose.yml >/dev/null
reach 198.51.100.2 8080 && fail "denied LAN address reachable (DOCKER-USER)"
reach 203.0.113.1 8080 && fail "denied host address reachable (INPUT)"
reach 192.0.2.2 8080 || fail "address outside the list blocked"
[ "$(drops 198.51.100.0/24)" -gt 0 ] || fail "no drop counted for the LAN network"
[ "$(drops 203.0.113.0/24)" -gt 0 ] || fail "no drop counted for the host network"
ok "apply: LAN (forwarded) and host (input) denied, the rest reachable"

on_host ip6tables -C DIND-DENY-br-hd-test -d 2001:db8::/32 -j DROP || fail "IPv6 rule missing"
for parent in DOCKER-USER INPUT; do
	on_host ip6tables -C "$parent" -i br-hd-test -j DIND-DENY-br-hd-test || fail "ip6tables jump from $parent missing"
done
ok "apply: IPv6 network in ip6tables, both jumps"

[ "$(on_host cat /run/dind-env-deny/br-hd-test)" = "$(printf '%s\n' 198.51.100.0/24 2001:db8::/32 203.0.113.0/24)" ] ||
	fail "list file: $(on_host cat /run/dind-env-deny/br-hd-test)"
ok "apply: list written to /run/dind-env-deny/br-hd-test, sorted"

# Replies: a connection the host starts towards the container is not cut by the
# DROP on the way back (the reply has the host's address as destination).
on_host sh -c 'docker exec -d hd-dind-1 /bin/busybox nc -lk -p 9090 -e /bin/busybox true'
agent_ip="$(on_host docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' hd-dind-1)"
on_host timeout 6 busybox nc -w 2 -s 203.0.113.1 "$agent_ip" 9090 </dev/null >/dev/null 2>&1 ||
	fail "reply to a host-started connection dropped"
ok "apply: replies to connections the host starts let through"

hd /hd/compose.yml >/dev/null
for parent in DOCKER-USER INPUT; do
	n="$(on_host sh -c "iptables -S $parent | grep -c -- '-j DIND-DENY-br-hd-test'")"
	[ "$n" = 1 ] || fail "$parent has $n jumps after a second apply"
done
n="$(on_host sh -c "iptables -S DIND-DENY-br-hd-test | grep -c -- '-j DROP'")"
[ "$n" = 2 ] || fail "chain has $n DROP rules after a second apply, want 2"
ok "apply: idempotent (one jump each, one rule per network)"

# --- the compose's list changes (here through the environment it interpolates)
docker exec -u 0 -w /work -e DENY_NETWORK=198.51.100.0/24 "$HOST" /work/scripts/host-deny.sh /hd/compose.yml >/dev/null
reach 203.0.113.1 8080 || fail "network dropped from the list still denied"
reach 198.51.100.2 8080 && fail "network kept in the list no longer denied"
on_host ip6tables -n -L DIND-DENY-br-hd-test >/dev/null 2>&1 && fail "ip6tables chain left with no IPv6 network"
[ "$(on_host cat /run/dind-env-deny/br-hd-test)" = 198.51.100.0/24 ] || fail "list file not updated"
ok "list changed: apply follows it, list file updated"

# --- remove
hd /hd/compose.yml remove >/dev/null
reach 198.51.100.2 8080 || fail "LAN address still denied after remove"
reach 203.0.113.1 8080 || fail "host address still denied after remove"
for ipt in iptables ip6tables; do
	grep -qF DIND-DENY <<<"$(on_host "$ipt"-save)" && fail "$ipt rules left after remove"
done
on_host iptables -n -L DOCKER-USER >/dev/null || fail "remove took DOCKER-USER away"
on_host test ! -e /run/dind-env-deny/br-hd-test || fail "list file left after remove"
on_host test -d /run/dind-env-deny || fail "remove took the list directory away"
ok "remove: reachable again, no rule, chain or list left, DOCKER-USER and the directory kept"

echo "all checks passed"
