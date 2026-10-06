#!/usr/bin/env bash
# shellcheck disable=SC2016 # single-quoted commands run in the container's shell
#
# Smoke test for a built image, full or minimal (detected):
#
#   tests/smoke.sh IMAGE [CYCLES]
#
# Covers startup, HOME under sudo, the shell prompt, DIND_DNS,
# DOCKER_DAEMON_INTERNAL_BIP, dotfile backup, the data-root lock, graceful stop,
# CYCLES hard kills, a double SIGTERM and a dockerd crash.
# Needs a Docker host that allows --privileged; no registry access, the inner
# workload image is built from the dind container's own busybox. Everything it
# creates is named dind-smoke-<pid>-* and removed on exit.
set -euo pipefail

IMAGE="${1:?usage: $0 IMAGE [CYCLES]}"
CYCLES="${2:-3}"
ID="dind-smoke-$$"
MAIN="$ID-main"
SECOND="$ID-second"
DATA="$ID-data"
HOMEV="$ID-home"
FULL=false

cleanup() {
	docker rm -f "$MAIN" "$SECOND" >/dev/null 2>&1 || true
	docker volume rm -f "$DATA" "$HOMEV" >/dev/null 2>&1 || true
}
trap cleanup EXIT

ok() { printf 'ok   - %s\n' "$*"; }

fail() {
	printf 'FAIL - %s\n' "$*" >&2
	docker logs --tail 40 "$MAIN" >&2 2>&1 || true
	exit 1
}

# Occurrences of a fixed string in the main container's log, all boots.
count() { docker logs "$MAIN" 2>&1 | grep -cF -- "$1" || true; }

in_main() { docker exec "$MAIN" "$@"; }

wait_ready() {
	for _ in $(seq 1 120); do
		if in_main docker version >/dev/null 2>&1; then
			return 0
		fi
		if [ "$(docker inspect -f '{{.State.Running}}' "$MAIN")" != true ]; then
			fail "container stopped while starting (exit $(docker inspect -f '{{.State.ExitCode}}' "$MAIN"))"
		fi
		sleep 1
	done
	fail "inner Docker API not answering after 120s"
}

# PM2 startup finishes after the daemon answers: wait until every launch
# logged its end.
wait_pm2() {
	[ "$FULL" = true ] || return 0
	for _ in $(seq 1 60); do
		if [ "$(count 'PM2 startup complete')" = "$(count 'launching Docker daemon')" ]; then
			return 0
		fi
		sleep 1
	done
	fail "PM2 startup did not complete"
}

# The inner --restart unless-stopped container, back after every restart.
wait_workload() {
	for _ in $(seq 1 60); do
		if [ "$(in_main docker inspect -f '{{.State.Running}}' box 2>/dev/null)" = true ]; then
			return 0
		fi
		sleep 1
	done
	fail "inner workload not running"
}

boot() {
	docker start "$MAIN" >/dev/null
	wait_ready
	wait_pm2
	wait_workload
}

# Prints the exit code.
wait_exit() {
	timeout 90 docker wait "$MAIN" || fail "container did not exit within 90s"
}

pm2_pid() { in_main cat /home/alpine/.pm2/pm2.pid 2>/dev/null || true; }

# The main instance must survive what other containers on its volumes do.
main_undisturbed() {
	in_main docker version >/dev/null 2>&1 || fail "$1: main daemon no longer answers"
	wait_workload
	if [ "$FULL" = true ]; then
		[ "$(pm2_pid)" = "$PM2_PID" ] || fail "$1: main PM2 daemon replaced"
		in_main test -S /home/alpine/.pm2/rpc.sock || fail "$1: main PM2 socket removed"
	fi
}

echo "image: $IMAGE, hard kill cycles: $CYCLES"
docker volume create "$DATA" >/dev/null
docker volume create "$HOMEV" >/dev/null

# A .bashrc of the user's own, without the dind-env- marker.
docker run --rm --entrypoint sh -v "$HOMEV:/home/alpine" "$IMAGE" \
	-c 'echo "# my own bashrc" > /home/alpine/.bashrc'

docker create --name "$MAIN" --privileged --stop-timeout 60 \
	-e DIND_DNS="192.0.2.53, not-an-ip,198.51.100.53" \
	-e DOCKER_DAEMON_INTERNAL_BIP=10.10.100.0/24 \
	-e DIND_ENVIRONMENT_NAME=smokeenv \
	-v "$DATA:/var/lib/docker" -v "$HOMEV:/home/alpine" \
	"$IMAGE" >/dev/null
docker start "$MAIN" >/dev/null
wait_ready
if in_main sh -c 'command -v pm2' >/dev/null 2>&1; then
	FULL=true
fi
wait_pm2
ok "daemon starts and answers (full variant: $FULL)"

[ "$(count 'Tini is not running as PID 1')" = 0 ] || fail "tini warns it is no subreaper"
ok "tini runs as subreaper"

[ "$(count "DIND_DNS entry 'not-an-ip' is not an IP address")" = 1 ] ||
	fail "invalid DIND_DNS entry not reported"
ok "invalid DIND_DNS entry dropped with a warning"

in_main sh -c 'grep -q dind-env- ~/.bashrc && grep -q "my own bashrc" ~/.bashrc.dind-env-backup.*' ||
	fail "unmarked .bashrc not moved aside"
ok "unmarked dotfile moved aside, seeded copy installed"

[ "$(in_main sh -c 'echo "$HOME"')" = /home/alpine ] || fail "alpine HOME"
[ "$(in_main sudo sh -c 'echo "$HOME"')" = /root ] || fail "sudo keeps HOME=/home/alpine"
[ "$(docker exec -u root "$MAIN" sh -c 'echo "$HOME"')" = /root ] || fail "exec -u root: HOME is not /root"
out="$(in_main sudo -i true 2>&1)" || fail "sudo -i failed: $out"
[ -z "$out" ] || fail "sudo -i login shell prints: $out"
ok "HOME follows the user (alpine, sudo, sudo -i, exec -u root)"

# Prompt: user@host in green/red, (DIND_ENVIRONMENT_NAME) yellow, (branch) cyan.
prompt() {
	docker exec -u "$1" -e TERM=xterm-256color "$MAIN" \
		bash -ic 'git init -q -b main /tmp/prompt-repo && cd /tmp/prompt-repo && printf "%s" "${PS1@P}"' 2>/dev/null |
		sed 's/[\x01\x02]//g'
}
for u in alpine:32 root:31; do
	p="$(prompt "${u%%:*}")"
	case "$p" in
	*$'\033[01;'"${u##*:}m${u%%:*}@"*$'\033[01;33m(smokeenv)'*$'\033[01;36m(main)'*) ;;
	*) fail "prompt for ${u%%:*} lacks colours, (smokeenv) or (main): $(printf '%s' "$p" | cat -v)" ;;
	esac
done
# sudo -i and su - drop the environment: the name comes from the file then.
p="$(docker exec -u root -e TERM=xterm-256color "$MAIN" env -u DIND_ENVIRONMENT_NAME \
	bash -ic 'printf "%s" "${PS1@P}"' 2>/dev/null)"
case "$p" in
*'(smokeenv)'*) ;;
*) fail "root prompt without DIND_ENVIRONMENT_NAME lost (smokeenv): $(printf '%s' "$p" | cat -v)" ;;
esac
[ "$(in_main sudo -i bash -c 'echo "$0 $(getent passwd root | cut -d: -f7)"')" = "-bash /bin/bash" ] ||
	fail "root login shell is not bash"
in_main sh -c 'rm -rf /tmp/prompt-repo; sudo rm -rf /tmp/prompt-repo'
ok "prompt: user@host green/red, (DIND_ENVIRONMENT_NAME) yellow, (branch) cyan, for alpine and root"

in_main sh -c 'cd / && tar -c bin/busybox lib/ld-musl-*.so.1 | docker import - smoke/box' >/dev/null
in_main docker run -d --name box --restart unless-stopped smoke/box /bin/busybox sleep 1000000 >/dev/null
wait_workload
resolv="$(in_main docker run --rm smoke/box /bin/busybox cat /etc/resolv.conf)"
case "$resolv" in
*192.0.2.53*198.51.100.53*) ;;
*) fail "DIND_DNS not applied to inner containers: $resolv" ;;
esac
ok "inner workload runs, DIND_DNS applied"

# A network address is turned into the first host for docker0.
bridge="$(in_main docker network inspect bridge -f '{{(index .IPAM.Config 0).Subnet}} {{(index .IPAM.Config 0).Gateway}}')"
[ "$bridge" = "10.10.100.0/24 10.10.100.1" ] || fail "DOCKER_DAEMON_INTERNAL_BIP not applied to docker0: $bridge"
inner_ip="$(in_main docker run --rm smoke/box /bin/busybox ip -4 -o addr show eth0)"
case "$inner_ip" in
*" 10.10.100."*) ;;
*) fail "inner container not on DOCKER_DAEMON_INTERNAL_BIP subnet: $inner_ip" ;;
esac
ok "DOCKER_DAEMON_INTERNAL_BIP: docker0 on 10.10.100.1/24, inner containers on that subnet"

if [ "$FULL" = true ]; then
	path="$(in_main bash -lc 'echo "$PATH"')"
	case ":$path:" in
	*:/opt/venv/bin:*) ;;
	*) fail "login shell PATH lost the venv: $path" ;;
	esac
	in_main sh -c 'touch /opt/venv/.smoke && rm /opt/venv/.smoke' || fail "/opt/venv not writable by alpine"
	restarts="$(in_main sh -c "pm2 jlist | jq -r '.[] | select(.name == \"pm2-logrotate\") | .pm2_env.restart_time'")"
	[ "$restarts" = 0 ] || fail "pm2-logrotate restarted at boot: '$restarts'"
	ok "full: login PATH keeps the venv, venv writable, boot leaves pm2-logrotate alone"
fi
PM2_PID="$(pm2_pid)"

# A second container on the same volumes: no second dockerd, and hands off
# the running instance (daemon, workload, PM2 socket in the shared home).
# Without the lock it would keep running on the shared data-root: the timeout
# turns that into a failure (124) instead of a hang.
start=$SECONDS
rc=0
timeout 60 docker run --name "$SECOND" --privileged \
	-v "$DATA:/var/lib/docker" -v "$HOMEV:/home/alpine" \
	"$IMAGE" >/dev/null 2>&1 || rc=$?
elapsed=$((SECONDS - start))
[ "$rc" = 75 ] || fail "second container exit $rc, want 75: $(docker logs "$SECOND" 2>&1 | tail -n 5)"
docker logs "$SECOND" 2>&1 | grep -qF 'in use by another container' || fail "second container: no lock error"
[ "$elapsed" -lt 30 ] || fail "second container took ${elapsed}s to give up"
docker rm "$SECOND" >/dev/null
main_undisturbed "second container"
ok "second dockerd on the same data-root refused (exit 75 in ${elapsed}s), main untouched"

out="$(docker run --rm -v "$DATA:/var/lib/docker" -v "$HOMEV:/home/alpine" "$IMAGE" sh -c 'echo cmd-ok')"
printf '%s\n' "$out" | grep -qx cmd-ok || fail "command path: $out"
main_undisturbed "command container"
ok "command path runs next to the daemon, main untouched"

terms=$(count "Processing signal 'terminated'")
dones=$(count 'Daemon shutdown complete')
docker stop -t 60 "$MAIN" >/dev/null
code="$(docker inspect -f '{{.State.ExitCode}}' "$MAIN")"
[ "$code" = 0 ] || fail "docker stop: exit $code"
[ "$(count "Processing signal 'terminated'")" = $((terms + 1)) ] || fail "docker stop: dockerd got more than one SIGTERM"
[ "$(count 'Daemon shutdown complete')" = $((dones + 1)) ] || fail "docker stop: dockerd did not shut down cleanly"
ok "docker stop: one SIGTERM, clean shutdown, exit 0"

boot
ok "restart after docker stop: daemon and inner workload back"

for n in $(seq 1 "$CYCLES"); do
	docker kill "$MAIN" >/dev/null
	docker wait "$MAIN" >/dev/null
	boot
	ok "hard kill $n/$CYCLES: daemon and inner workload back"
done

dones=$(count 'Daemon shutdown complete')
docker kill -s TERM "$MAIN" >/dev/null
sleep 1
docker kill -s TERM "$MAIN" >/dev/null 2>&1 || true
code="$(wait_exit)"
[ "$code" = 0 ] || fail "double SIGTERM: exit $code"
[ "$(count 'Daemon shutdown complete')" = $((dones + 1)) ] || fail "double SIGTERM: no clean dockerd shutdown"
[ "$(count 'Forcing docker daemon shutdown without cleanup')" = 0 ] || fail "dockerd forced its shutdown"
ok "double SIGTERM: still one clean shutdown, exit 0"

boot
in_main sudo sh -c 'kill -KILL "$(cat /var/run/docker.pid)"'
code="$(wait_exit)"
[ "$code" != 0 ] || fail "dockerd crash: container exit 0"
ok "dockerd crash: container exits $code"
boot
ok "restart after a dockerd crash: daemon and inner workload back"

echo "all checks passed"
