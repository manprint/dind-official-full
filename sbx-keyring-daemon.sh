#!/bin/sh
# Secret Service of the sbx image: gnome-keyring-daemon with the login keyring
# unlocked. D-Bus starts it (org.freedesktop.secrets) at the first request and
# again after a crash: the stock service file would bring it back locked, and
# every sbx login, secret and sandbox create then fails with "the OS keychain
# is locked". Its stderr goes to $XDG_RUNTIME_DIR/gnome-keyring.log.
set -eu

KEYRING_PASS_FILE="${SBX_KEYRING_PASS_FILE:-/run/secrets/sbx/keyring_pass}"
# Written by entrypoint.sbx.sh when KEYRING_PASS_FILE is missing.
FALLBACK_PASS_FILE=/home/alpine/.local/share/keyrings/.dind-env-keyring-pass
LOG="${XDG_RUNTIME_DIR:-/run/user/1000}/gnome-keyring.log"

if sudo -n test -s "$KEYRING_PASS_FILE"; then
	pass="$KEYRING_PASS_FILE"
else
	pass="$FALLBACK_PASS_FILE"
fi
echo "$(date -Iseconds) gnome-keyring-daemon starting (pid $$)" >>"$LOG"
sudo -n cat "$pass" | tr -d '\n' | gnome-keyring-daemon --foreground --unlock --components=secrets 2>>"$LOG" || rc=$?
echo "$(date -Iseconds) gnome-keyring-daemon exited (status ${rc:-0})" >>"$LOG"
exit "${rc:-0}"
