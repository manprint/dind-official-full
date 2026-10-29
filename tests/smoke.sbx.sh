#!/usr/bin/env bash
# shellcheck disable=SC2016 # single-quoted commands run in the container's shell
#
# Smoke test for the sbx image (Dockerfile.sbx):
#
#   tests/smoke.sbx.sh IMAGE [CYCLES]
#
# Covers startup under tini, dockerd and the sbx daemon (what the compose
# healthcheck waits for), the sbx CLI reaching the daemon, the keyring password
# file, the keyring unlocked and holding an item, gnome-keyring brought back
# unlocked after a crash, the memlock limit, the mount points handed to
# alpine, the backup scripts in /opt/sbx-backup-scripts, CYCLES hard kills
# restarted on the same volumes, and a graceful stop that stops sbx before
# dockerd. No sbx login and no sandbox: a login needs a Docker account, a
# sandbox needs KVM, which most CI runners lack (the entrypoint only warns).
# Needs a Docker host that allows --privileged; no registry access.
# Everything it creates is named dind-smoke-sbx-<pid>-* and removed on exit.
set -euo pipefail

IMAGE="${1:?usage: $0 IMAGE [CYCLES]}"
CYCLES="${2:-3}"
ID="dind-smoke-sbx-$$"
MAIN="$ID-main"
DATA="$ID-data"
HOMEV="$ID-home"
STATE="$ID-state"
TMPD="$(mktemp -d)"

cleanup() {
	docker rm -f "$MAIN" >/dev/null 2>&1 || true
	docker volume rm -f "$DATA" "$HOMEV" "$STATE" >/dev/null 2>&1 || true
	rm -rf "$TMPD"
}
trap cleanup EXIT

ok() { printf 'ok   - %s\n' "$*"; }

fail() {
	printf 'FAIL - %s\n' "$*" >&2
	docker logs --tail 40 "$MAIN" >&2 2>&1 || true
	exit 1
}

# Occurrences of a fixed string in the container's log, all boots.
count() { docker logs "$MAIN" 2>&1 | grep -cF -- "$1" || true; }

# As alpine in a login shell: /etc/profile.d exports the session bus address.
in_main() { docker exec -u alpine "$MAIN" bash -lc "$1"; }

# Python against the Secret Service, as sbx uses it.
py() { docker exec -u alpine -e PY="$1" "$MAIN" bash -lc 'python3 -c "$PY"'; }
PY_STATE='import secretstorage as s; print("locked" if s.get_default_collection(s.dbus_init()).is_locked() else "unlocked")'
PY_SET='import secretstorage as s; s.get_default_collection(s.dbus_init()).create_item("dind-smoke", {"dind-smoke": "1"}, b"smoke-value", replace=True)'
PY_GET='import secretstorage as s; i = list(s.search_items(s.dbus_init(), {"dind-smoke": "1"})); print(i[0].get_secret().decode() if i else "missing")'

wait_ready() {
	for _ in $(seq 1 180); do
		if in_main 'docker version >/dev/null 2>&1 && sbx daemon status 2>/dev/null | grep -qw running'; then
			return 0
		fi
		if [ "$(docker inspect -f '{{.State.Running}}' "$MAIN")" != true ]; then
			fail "container stopped while starting (exit $(docker inspect -f '{{.State.ExitCode}}' "$MAIN"))"
		fi
		sleep 1
	done
	fail "dockerd or the sbx daemon not ready after 180s"
}

# The keyring is unlocked and still holds the item written at the first boot.
# A request right after a gnome-keyring crash may fail once, hence the retries.
check_keyring() {
	local state="" value=""
	for _ in $(seq 1 15); do
		state="$(py "$PY_STATE" 2>/dev/null || true)"
		value="$(py "$PY_GET" 2>/dev/null || true)"
		[ "$state" = unlocked ] && [ "$value" = smoke-value ] && return 0
		sleep 1
	done
	fail "$1: keyring $state, item ${value:-unreadable}"
}

mkdir "$TMPD/secrets"
head -c 32 /dev/urandom | base64 | tr -d '\n' >"$TMPD/secrets/keyring_pass"
docker run -d --name "$MAIN" --privileged --ulimit memlock=-1 \
	-e SBX_KEYRING_PASS_FILE=/run/secrets/sbx/keyring_pass \
	-v "$TMPD/secrets:/run/secrets/sbx:ro" \
	-v "$DATA:/var/lib/docker" -v "$HOMEV:/home/alpine" \
	-v "$STATE:/home/alpine/.local/state/sandboxes" \
	"$IMAGE" >/dev/null
wait_ready
ok "dockerd and the sbx daemon running"

[ "$(docker exec "$MAIN" cat /proc/1/comm)" = tini ] || fail "PID 1 is not tini"
ok "PID 1 is tini"

version="$(in_main 'sbx version')"
grep -q 'v[0-9]' <<<"$version" || fail "sbx version: $version"
# Without a login every API call answers "not signed in": the CLI reached the daemon.
answer="$(in_main 'sbx ls 2>&1' || true)"
grep -qE 'not signed in|SANDBOX' <<<"$answer" || fail "sbx ls: $answer"
ok "sbx CLI reaches the daemon ($version)"

[ "$(count 'no keyring password')" = 0 ] || fail "keyring password file ignored"
[ "$(py "$PY_STATE")" = unlocked ] || fail "keyring locked after start"
py "$PY_SET"
check_keyring "first boot"
ok "keyring unlocked with the password file, item stored"

docker exec "$MAIN" pkill -9 -f gnome-keyring-daemon
check_keyring "after a gnome-keyring crash"
ok "gnome-keyring back unlocked after a crash"

[ "$(in_main 'ulimit -l')" = unlimited ] || fail "memlock limit not raised"
ok "memlock unlimited"

owners="$(in_main 'stat -c %U ~/.local/state/sandboxes ~/.local/share/keyrings ~/.config/sandboxes' | sort -u)"
[ "$owners" = alpine ] || fail "sbx directories not owned by alpine: $owners"
ok "sbx directories owned by alpine"

scripts="$(docker exec "$MAIN" sh -c 'n=0; for f in /opt/sbx-backup-scripts/*/*.sh; do [ -x "$f" ] && bash -n "$f" || exit 1; n=$((n + 1)); done; echo "$n"')" \
	|| fail "backup scripts missing, not executable or not valid bash"
[ "$scripts" = 6 ] || fail "$scripts backup scripts, expected 6"
ok "6 backup scripts in /opt/sbx-backup-scripts"

for i in $(seq 1 "$CYCLES"); do
	docker kill "$MAIN" >/dev/null
	docker start "$MAIN" >/dev/null
	wait_ready
	check_keyring "after kill $i"
	ok "hard kill $i/$CYCLES: restarted, keyring unlocked, item kept"
done

t0=$(date +%s)
docker stop -t 120 "$MAIN" >/dev/null
elapsed=$(($(date +%s) - t0))
code="$(docker inspect -f '{{.State.ExitCode}}' "$MAIN")"
[ "$code" = 0 ] || fail "graceful stop: exit $code"
[ "$elapsed" -lt 60 ] || fail "graceful stop took ${elapsed}s"
order="$(docker logs "$MAIN" 2>&1 | grep -nE '\[sbx-entrypoint\] sbx stopped|Processing signal .terminated.' | tail -n 2 | cut -d: -f2-)"
grep -q 'sbx stopped' <<<"$(head -n 1 <<<"$order")" || fail "dockerd stopped before sbx: $order"
ok "graceful stop in ${elapsed}s, exit 0, sbx stopped before dockerd"
