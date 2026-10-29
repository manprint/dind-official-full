#!/usr/bin/env bash
# =============================================================================
#  Strategia B — BACKUP RAW "a freddo" 1:1 di tutto lo stato Docker Sandboxes
#
#  Copia byte-per-byte (sparse-aware) le cartelle di stato di sbx:
#    ~/.local/state/sandboxes   containerd, snapshot rootfs, volumi block, spec
#    ~/.cache/sandboxes         policy (governor.db), feature flag
#    ~/.config/sandboxes        settings (sbx settings set ...: es. disco DinD, kit shortcut)
#    ~/.config/sbx              credential bindings (sbx env), se presente
#    ~/.config/com.docker.sandboxes  file dei secret quando manca il Secret Service, se presente
#    ~/.local/share/sandboxes   dati client (analytics, sessione)
#    ~/.sbx                     runtime dir
#  Dentro lo stato ci sono anche: skill store (sbx skills), registro MCP (sbx mcp),
#  kit scaricati, template salvati, spec di ogni sandbox (env, kit, porte, MCP).
#  + opzionali: workspace host, credenziali keyring (cifrate gpg).
#
#  ATTENZIONE: per la consistenza FERMA TUTTE le sandbox e il daemon sbx,
#  poi (se configurato) li riavvia. Copre TUTTE le sandbox e i template.
#
#  Output: UN SOLO file <BACKUP_NAME>.tar.zst (o .tar.gz / .tar) con dentro:
#    meta.tar                   manifest.env + metadata/ + secrets.json.gpg (primo membro)
#    .local/state/sandboxes/... .cache/sandboxes/... .sbx/...   (relativi alla HOME)
#    <percorsi workspace>       (relativi a /, opzionale)
#    <file host MCP>            script/binari dei server MCP locali (relativi a /)
#
#  Uso:   ./backup.sh                 (chiede conferma prima di fermare)
#         ASSUME_YES=1 BACKUP_DIR=/mnt/usb ./backup.sh
# =============================================================================
set -Eeuo pipefail

# ============================== CONFIGURAZIONE ===============================
# Ogni variabile si può sovrascrivere da ambiente: VAR=valore ./backup.sh
SOURCE_HOME="${SOURCE_HOME:-$HOME}"                                  # home che contiene lo stato sbx
SBX_STATE_DIR="${SBX_STATE_DIR:-$SOURCE_HOME/.local/state/sandboxes}"
SBX_CACHE_DIR="${SBX_CACHE_DIR:-$SOURCE_HOME/.cache/sandboxes}"
SBX_RUN_DIR="${SBX_RUN_DIR:-$SOURCE_HOME/.sbx}"
SBX_CONFIG_DIR="${SBX_CONFIG_DIR:-$SOURCE_HOME/.config/sandboxes}"   # settings.json
SBX_BINDINGS_DIR="${SBX_BINDINGS_DIR:-$SOURCE_HOME/.config/sbx}"     # credentials.yaml (binding sbx env)
SBX_DATA_DIR="${SBX_DATA_DIR:-$SOURCE_HOME/.local/share/sandboxes}"
SBX_SECRETS_FALLBACK_DIR="${SBX_SECRETS_FALLBACK_DIR:-$SOURCE_HOME/.config/com.docker.sandboxes}"  # secret senza keyring
BACKUP_DIR="${BACKUP_DIR:-$HOME/sbx-backups}"                        # destinazione
STAMP="${STAMP:-$(date +%Y%m%d-%H%M%S)}"
BACKUP_NAME="${BACKUP_NAME:-sbxB-full-$(hostname -s)-${STAMP}}"      # nome file (senza estensione)

COMPRESSOR="${COMPRESSOR:-zstd}"                                     # zstd | gzip | none
COMPRESS_LEVEL="${COMPRESS_LEVEL:-3}"                                # zstd 1-19, gzip 1-9
INCLUDE_LOGS="${INCLUDE_LOGS:-0}"                                    # 1 = includi daemon.log, crash, ecc.
INCLUDE_WORKSPACES="${INCLUDE_WORKSPACES:-0}"                        # 1 = includi i workspace host di tutte le sandbox
WORKSPACES_OVERRIDE="${WORKSPACES_OVERRIDE:-}"                       # lista workspace esplicita (vuoto = da "sbx ls")
WORKSPACE_EXCLUDES="${WORKSPACE_EXCLUDES:-}"                         # pattern tar --exclude separati da spazio
INCLUDE_MCP_HOST_FILES="${INCLUDE_MCP_HOST_FILES:-1}"                # file host dei server MCP locali (percorsi assoluti nel comando)

INCLUDE_SECRETS="${INCLUDE_SECRETS:-1}"                              # credenziali sbx dal keyring, cifrate gpg
INCLUDE_DOCKER_LOGIN="${INCLUDE_DOCKER_LOGIN:-0}"                    # anche login Docker Hub di sbx (meglio "sbx login")
SECRETS_PASSPHRASE_FILE="${SECRETS_PASSPHRASE_FILE:-}"               # file passphrase gpg; vuoto = interattiva
SECRETS_ID_FILTER="${SECRETS_ID_FILTER:-}"                           # regex sugli id dei secret (vuoto = tutti)

TRIM_DIND_BEFORE_STOP="${TRIM_DIND_BEFORE_STOP:-1}"                  # fstrim /var/lib/docker: riduce i .img sparse
ASSUME_YES="${ASSUME_YES:-0}"                                        # 1 = niente conferma prima dello stop
STOP_TIMEOUT="${STOP_TIMEOUT:-120}"                                  # secondi di attesa arresto daemon
RESTART_DAEMON_AFTER="${RESTART_DAEMON_AFTER:-1}"                    # riavvia daemon a fine backup (anche su errore)
RESTART_SANDBOXES_AFTER="${RESTART_SANDBOXES_AFTER:-1}"              # riavvia (detached) le sandbox che erano running
WRITE_SHA256_SIDECAR="${WRITE_SHA256_SIDECAR:-1}"                    # scrive anche <file>.sha256
UNSAFE_SKIP_STOP="${UNSAFE_SKIP_STOP:-0}"                            # SOLO TEST: non ferma nulla → copia inconsistente
SBX_BIN="${SBX_BIN:-sbx}"
# =============================================================================

log()  { printf '\033[1;34m[B-backup]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[B-backup] ATTENZIONE:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[B-backup] ERRORE:\033[0m %s\n' "$*" >&2; exit 1; }
# Percorsi assoluti esistenti nominati dal comando (o dalla cwd) dei server MCP
# registrati in $1, esclusi quelli di sistema (interpreti, /etc, pseudo-fs).
mcp_host_paths() {
  local f p
  for f in "$1"/*.json; do
    [[ -e "$f" ]] || continue
    jq -r '[.spec.Command[]?, (.spec.Cwd // empty)] | .[] | select(startswith("/"))' "$f"
  done | sort -u | while IFS= read -r p; do
    case "$p" in /usr/* | /bin/* | /sbin/* | /lib/* | /lib64/* | /etc/* | /proc/* | /sys/* | /dev/* | /run/*) continue ;; esac
    [[ -e "$p" ]] && printf '%s\n' "$p"
  done
}
need() { command -v "$1" >/dev/null 2>&1 || die "comando mancante: $1"; }
daemon_running() { pgrep -u "$(id -u)" -f "$(basename "$SBX_BIN") daemon start" >/dev/null 2>&1; }

case "$COMPRESSOR" in
  zstd) need zstd; EXT=".tar.zst"; compress() { zstd -q -T0 "-${COMPRESS_LEVEL}" -c; } ;;
  gzip) EXT=".tar.gz"
        if command -v pigz >/dev/null 2>&1; then compress() { pigz -c "-${COMPRESS_LEVEL}"; }
        else compress() { gzip -c "-${COMPRESS_LEVEL}"; }; fi ;;
  none) EXT=".tar"; compress() { cat; } ;;
  *)    die "COMPRESSOR non valido: $COMPRESSOR (zstd|gzip|none)" ;;
esac

PY_EXPORT_SECRETS='
import base64, json, sys
import secretstorage
import re
inc_login, flt = sys.argv[1] == "1", sys.argv[2]
conn = secretstorage.dbus_init()
groups = ["com.docker.sandboxes"] + (["com.docker.sandboxes-auth"] if inc_login else [])
out = []
for g in groups:
    for it in secretstorage.search_items(conn, {"service:group": g}):
        attrs = dict(it.get_attributes())
        if flt and not re.search(flt, attrs.get("id", "")):
            continue
        if it.is_locked():
            it.unlock()
        ctype = getattr(it, "get_secret_content_type", lambda: "text/plain")()
        out.append({"label": it.get_label(), "attributes": attrs, "content_type": ctype,
                    "secret": base64.b64encode(it.get_secret()).decode()})
        print("  secret:", attrs.get("id", it.get_label()), file=sys.stderr)
json.dump(out, sys.stdout)
print("%d secret esportati" % len(out), file=sys.stderr)
'

# ------------------------------ preflight ------------------------------------
for c in "$SBX_BIN" tar jq sha256sum pgrep; do need "$c"; done
[[ "$INCLUDE_SECRETS" == 1 ]] && { need gpg; need python3
  python3 -I -c 'import secretstorage' 2>/dev/null || die "python3-secretstorage mancante (apt install python3-secretstorage) oppure INCLUDE_SECRETS=0"; }
[[ -z "$SECRETS_PASSPHRASE_FILE" || -r "$SECRETS_PASSPHRASE_FILE" ]] || die "SECRETS_PASSPHRASE_FILE non leggibile"

SOURCE_HOME=$(cd "$SOURCE_HOME" && pwd -P)
REL=()
for d in "$SBX_STATE_DIR" "$SBX_CACHE_DIR" "$SBX_RUN_DIR" "$SBX_CONFIG_DIR" "$SBX_BINDINGS_DIR" "$SBX_DATA_DIR" "$SBX_SECRETS_FALLBACK_DIR"; do
  [[ -d "$d" ]] || { [[ "$d" == "$SBX_BINDINGS_DIR" || "$d" == "$SBX_SECRETS_FALLBACK_DIR" ]] || warn "cartella assente, salto: $d"; continue; }
  [[ -n "$(ls -A "$d" 2>/dev/null)" ]] || continue   # cartella vuota (es. mount point): niente da copiare
  d=$(cd "$d" && pwd -P)
  [[ "$d" == "$SOURCE_HOME"/* ]] || die "$d non è sotto SOURCE_HOME=$SOURCE_HOME"
  REL+=("${d#"$SOURCE_HOME"/}")
done
((${#REL[@]})) || die "nessuna cartella di stato sbx trovata"

mkdir -p "$BACKUP_DIR"; BACKUP_DIR=$(cd "$BACKUP_DIR" && pwd -P)
ARCHIVE="$BACKUP_DIR/$BACKUP_NAME$EXT"; PARTIAL="$ARCHIVE.partial"
[[ -e "$ARCHIVE" || -e "$PARTIAL" ]] && die "esiste già $ARCHIVE"
for r in "${REL[@]}"; do [[ "$BACKUP_DIR/" == "$SOURCE_HOME/$r/"* ]] && die "BACKUP_DIR dentro la cartella di stato $r"; done

STATE_BYTES=$(du -sB1 "${REL[@]/#/$SOURCE_HOME/}" | awk '{s+=$1} END {print s}')
AVAIL=$(df -B1 --output=avail "$BACKUP_DIR" | tail -1 | tr -d ' ')
log "stato sbx: $((STATE_BYTES >> 20)) MiB reali; libero in $BACKUP_DIR: $((AVAIL >> 20)) MiB"
(( AVAIL > STATE_BYTES )) || warn "spazio potenzialmente insufficiente (dipende dalla compressione)"

META=$(mktemp -d); trap 'rm -rf -- "$META"' EXIT
mkdir -p "$META/metadata"

# ------------------------------ metadati (daemon ancora attivo) --------------
SBX_LS='[]'; RUNNING=(); WORKSPACES=()
if [[ "$SOURCE_HOME" == "$(cd "$HOME" && pwd -P)" ]]; then   # il daemon descrive questo stato solo se è la HOME reale
  SBX_LS=$("$SBX_BIN" ls --json 2>/dev/null || echo '[]')
  mapfile -t RUNNING < <(jq -r '.[] | select(.status == "running") | .name' <<<"$SBX_LS")
  mapfile -t WORKSPACES < <(jq -r '[.[].workspaces[]?] | unique | .[] | sub(":ro$"; "")' <<<"$SBX_LS")
  M="$META/metadata"
  jq . <<<"$SBX_LS"            > "$M/sandboxes.json"
  "$SBX_BIN" template ls       > "$M/templates.txt"    2>&1 || true
  "$SBX_BIN" secret ls         > "$M/secrets-list.txt" 2>&1 || true
  "$SBX_BIN" policy ls         > "$M/policy-global.txt" 2>&1 || true
  for s in $(jq -r '.[].name' <<<"$SBX_LS"); do "$SBX_BIN" policy ls "$s" > "$M/policy-$s.txt" 2>&1 || true; done
  "$SBX_BIN" settings ls 2>/dev/null | awk 'NR==1 || $4!="default"' > "$M/settings-overrides.txt" || true
fi
{ uname -a; cat /etc/os-release 2>/dev/null; id; } > "$META/metadata/host.txt"

# shellcheck disable=SC2206  # lista separata da spazi voluta
[[ -n "$WORKSPACES_OVERRIDE" ]] && WORKSPACES=($WORKSPACES_OVERRIDE)
WS_INC=()
if [[ "$INCLUDE_WORKSPACES" == 1 ]]; then
  for ws in "${WORKSPACES[@]}"; do
    if [[ -d "$ws" ]]; then WS_INC+=("$(cd "$ws" && pwd -P)"); else warn "workspace assente, salto: $ws"; fi
  done
fi

# Un server MCP locale gira sull'host: i file che il suo comando nomina con un
# percorso assoluto (fuori dai percorsi di sistema) non sono nello stato sbx.
MCP_INC=()
if [[ "$INCLUDE_MCP_HOST_FILES" == 1 ]]; then
  while IFS= read -r p; do
    for ws in "${WS_INC[@]}"; do [[ "$p" == "$ws"/* ]] && continue 2; done
    MCP_INC+=("$p")
  done < <(mcp_host_paths "$SBX_STATE_DIR/sandboxes/sandboxd/mcp/servers")
fi

{
  printf '%s=%q\n' FORMAT sbx-backup-B FORMAT_VERSION 1 \
    CREATED_AT "$(date -Iseconds)" SOURCE_HOST "$(hostname)" SOURCE_USER "$(id -un)" SOURCE_UID "$(id -u)" \
    SOURCE_HOME "$SOURCE_HOME" ARCH "$(uname -m)" SBX_VERSION "$("$SBX_BIN" version | awk '{print $3}')" \
    STATE_BYTES "$STATE_BYTES" REL_COUNT "${#REL[@]}" RUNNING "${RUNNING[*]}"
  for i in "${!REL[@]}"; do printf 'REL_%d=%q\n' "$i" "${REL[$i]}"; done
  printf 'WORKSPACE_COUNT=%d\n' "${#WS_INC[@]}"
  for i in "${!WS_INC[@]}"; do printf 'WORKSPACE_%d=%q\n' "$i" "${WS_INC[$i]}"; done
  printf 'MCPFILE_COUNT=%d\n' "${#MCP_INC[@]}"
  for i in "${!MCP_INC[@]}"; do printf 'MCPFILE_%d=%q\n' "$i" "${MCP_INC[$i]}"; done
} > "$META/manifest.env"

if [[ "$INCLUDE_SECRETS" == 1 ]]; then
  log "export credenziali dal keyring (cifrate gpg AES256)"
  GPG=(gpg --quiet --symmetric --cipher-algo AES256 --output "$META/secrets.json.gpg")
  [[ -n "$SECRETS_PASSPHRASE_FILE" ]] && GPG+=(--batch --yes --pinentry-mode loopback --passphrase-file "$SECRETS_PASSPHRASE_FILE")
  python3 -I -c "$PY_EXPORT_SECRETS" "$INCLUDE_DOCKER_LOGIN" "$SECRETS_ID_FILTER" | "${GPG[@]}"
fi
META_FILES=(manifest.env metadata); [[ -f "$META/secrets.json.gpg" ]] && META_FILES+=(secrets.json.gpg)
tar -cf "$META/meta.tar" -C "$META" "${META_FILES[@]}"

# ------------------------------ conferma + stop ------------------------------
STOPPED=0
restart_all() {
  [[ "$STOPPED" == 1 && "$RESTART_DAEMON_AFTER" == 1 ]] || return 0
  log "riavvio daemon sbx"
  "$SBX_BIN" daemon start --detach >/dev/null 2>&1 || warn "riavvio daemon fallito: lancia '$SBX_BIN daemon start --detach'"
  if [[ "$RESTART_SANDBOXES_AFTER" == 1 ]]; then
    for s in "${RUNNING[@]}"; do
      log "riavvio sandbox $s (detached)"
      "$SBX_BIN" run -d --name "$s" >/dev/null 2>&1 || warn "riavvio $s fallito: '$SBX_BIN run --name $s'"
    done
  fi
}
on_exit() { local rc=$?; rm -rf -- "$META"; [[ $rc -ne 0 ]] && rm -f -- "$PARTIAL"; restart_all; exit "$rc"; }
trap on_exit EXIT

if [[ "$UNSAFE_SKIP_STOP" == 1 ]]; then
  warn "UNSAFE_SKIP_STOP=1: copia a caldo, NON consistente (solo per test)"
else
  log "sandbox in esecuzione che verranno FERMATE: ${RUNNING[*]:-<nessuna>} (+ daemon sbx)"
  if [[ "$ASSUME_YES" != 1 ]]; then
    read -r -p "Procedo con lo stop? [si/NO] " ans < /dev/tty
    [[ "$ans" =~ ^(s|si|sì|y|yes)$ ]] || die "annullato dall'utente"
  fi
  if [[ "$TRIM_DIND_BEFORE_STOP" == 1 ]]; then
    for s in "${RUNNING[@]}"; do
      log "fstrim /var/lib/docker in $s"
      "$SBX_BIN" exec "$s" sh -c '[ -d /var/lib/docker ] && sudo -n fstrim -v /var/lib/docker' 2>&1 | sed 's/^/    /' >&2 \
        || warn "fstrim non riuscito in $s (non bloccante)"
    done
  fi
  STOPPED=1
  ((${#RUNNING[@]})) && { log "sbx stop ${RUNNING[*]}"; "$SBX_BIN" stop "${RUNNING[@]}"; }
  log "sbx daemon stop"
  "$SBX_BIN" daemon stop || true
  t=0; while daemon_running; do ((t += 2)); ((t > STOP_TIMEOUT)) && die "il daemon non si ferma"; sleep 2; done
fi

# ------------------------------ tar ------------------------------------------
EXCL=()
if [[ "$INCLUDE_LOGS" != 1 ]]; then
  EXCL+=(--exclude='*/sandboxd/*.log' --exclude='*/sandboxd/*.log.*' --exclude='*/sandboxd/*.log.gz'
         --exclude='*/sandboxd/crashes/*' --exclude='*/sandboxd/mcp/*.log')
fi
WS_ARGS=()
if ((${#WS_INC[@]})); then
  for p in $WORKSPACE_EXCLUDES; do EXCL+=("--exclude=$p"); done
  EXCL+=("--exclude=${BACKUP_DIR#/}")
  WS_ARGS=(-C /); for ws in "${WS_INC[@]}"; do WS_ARGS+=("${ws#/}"); done
  log "workspace inclusi: ${WS_INC[*]}"
fi
if ((${#MCP_INC[@]})); then
  ((${#WS_ARGS[@]})) || WS_ARGS=(-C /)
  for p in "${MCP_INC[@]}"; do WS_ARGS+=("${p#/}"); done
  log "file host dei server MCP: ${MCP_INC[*]}"
fi

log "creazione $ARCHIVE"
set +e
tar --sparse --warning=no-file-ignored "${EXCL[@]}" -cpf - \
    -C "$META" meta.tar -C "$SOURCE_HOME" "${REL[@]}" "${WS_ARGS[@]}" | compress > "$PARTIAL"
ST=("${PIPESTATUS[@]}")
set -e
if (( ST[0] == 1 )) && [[ "$UNSAFE_SKIP_STOP" == 1 ]]; then warn "file cambiati durante la copia (atteso a caldo)"
elif (( ST[0] != 0 )); then die "tar fallito (exit ${ST[0]})"; fi
(( ST[1] == 0 )) || die "compressione fallita (exit ${ST[1]})"

mv -- "$PARTIAL" "$ARCHIVE"
[[ "$WRITE_SHA256_SIDECAR" == 1 ]] && (cd "$BACKUP_DIR" && sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
log "OK → $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
