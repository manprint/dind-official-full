#!/usr/bin/env bash
# =============================================================================
#  Strategia B — RESTORE RAW "a freddo" 1:1 dello stato Docker Sandboxes
#
#  Prende l'archivio di backup.sh (.tar.zst / .tar.gz / .tar) e:
#    1. legge meta.tar, controlla versione sbx, arch, HOME, KVM, spazio
#    2. ferma daemon sbx locale (se attivo e la destinazione è la HOME reale)
#    3. sposta da parte (o rifiuta) uno stato sbx già presente
#    4. estrae lo stato (sparse) + workspace (opzionale)
#    5. importa credenziali nel keyring (se presenti)
#    6. riavvia daemon e (opzionale) le sandbox che erano running
#
#  REQUISITI: Linux stessa arch, stessa versione sbx, stessa HOME (/home/<utente>),
#  stessi percorsi workspace. I path assoluti sono scritti nei DB interni di sbx.
#  Uso:   ./restore.sh /percorso/sbxB-full-<host>-<data>.tar.zst
# =============================================================================
set -Eeuo pipefail

# ============================== CONFIGURAZIONE ===============================
# Ogni variabile si può sovrascrivere da ambiente: VAR=valore ./restore.sh file
BACKUP_FILE="${1:-${BACKUP_FILE:-}}"                       # archivio prodotto da backup.sh
TARGET_HOME="${TARGET_HOME:-$HOME}"                        # dove estrarre lo stato (deve = HOME originale)
EXISTING_STATE="${EXISTING_STATE:-abort}"                  # stato sbx già presente: abort | move (rinomina *.pre-restore-<data>)
STOP_DAEMON="${STOP_DAEMON:-1}"                            # ferma il daemon sbx locale se attivo
START_DAEMON_AFTER="${START_DAEMON_AFTER:-1}"              # avvia daemon a fine restore
START_SANDBOXES_AFTER="${START_SANDBOXES_AFTER:-0}"        # avvia (detached) le sandbox che erano running nel backup
RESTORE_WORKSPACES="${RESTORE_WORKSPACES:-auto}"           # auto = se presenti | 1 | 0
WORKSPACE_ROOT="${WORKSPACE_ROOT:-/}"                      # radice di estrazione workspace (≠ / rompe i path della spec)
WORKSPACE_OVERWRITE="${WORKSPACE_OVERWRITE:-0}"            # 1 = estrai anche su cartelle non vuote
RESTORE_MCP_HOST_FILES="${RESTORE_MCP_HOST_FILES:-1}"      # file host dei server MCP locali, solo se qui mancano
RESTORE_SECRETS="${RESTORE_SECRETS:-auto}"                 # auto = se presenti | 1 | 0
SECRETS_PASSPHRASE_FILE="${SECRETS_PASSPHRASE_FILE:-}"     # file passphrase gpg; vuoto = interattiva
CHECK_SBX_VERSION="${CHECK_SBX_VERSION:-1}"                # 1 = blocca se versione sbx diversa
CHECK_HOME_PATH="${CHECK_HOME_PATH:-1}"                    # 1 = blocca se TARGET_HOME ≠ HOME originale
CHECK_ARCH="${CHECK_ARCH:-1}"                              # 1 = blocca se architettura diversa
CHECK_KVM="${CHECK_KVM:-1}"                                # 1 = blocca se /dev/kvm non accessibile
ASSUME_YES="${ASSUME_YES:-0}"                              # 1 = niente conferme
STOP_TIMEOUT="${STOP_TIMEOUT:-120}"
SBX_BIN="${SBX_BIN:-sbx}"
# =============================================================================

log()  { printf '\033[1;34m[B-restore]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[B-restore] ATTENZIONE:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[B-restore] ERRORE:\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "comando mancante: $1"; }
daemon_running() { pgrep -u "$(id -u)" -f "$(basename "$SBX_BIN") daemon start" >/dev/null 2>&1; }
confirm() { [[ "$ASSUME_YES" == 1 ]] && return 0; read -r -p "$1 [si/NO] " a < /dev/tty; [[ "$a" =~ ^(s|si|sì|y|yes)$ ]]; }

PY_IMPORT_SECRETS='
import base64, json, sys
import secretstorage
data = json.load(sys.stdin)
conn = secretstorage.dbus_init()
col = secretstorage.get_default_collection(conn)
if col.is_locked():
    col.unlock()
for e in data:
    col.create_item(e["label"], dict(e["attributes"]), base64.b64decode(e["secret"]), replace=True,
                    content_type=e.get("content_type") or "text/plain")
    print("  importato:", e["attributes"].get("id", e["label"]), file=sys.stderr)
print("%d secret importati" % len(data), file=sys.stderr)
'

# ------------------------------ preflight ------------------------------------
[[ -n "$BACKUP_FILE" ]] || die "uso: $0 <backup.tar.zst>"
[[ -f "$BACKUP_FILE" ]] || die "file non trovato: $BACKUP_FILE"
for c in "$SBX_BIN" tar pgrep od jq; do need "$c"; done

case "$(head -c4 "$BACKUP_FILE" | od -An -tx1 | tr -d ' \n')" in
  28b52ffd) need zstd; DEC=(zstd -dc) ;;
  1f8b*)    DEC=(gzip -dc) ;;
  *)        DEC=(cat) ;;
esac
dec() { "${DEC[@]}" < "$BACKUP_FILE"; }

if [[ -f "$BACKUP_FILE.sha256" ]]; then
  log "verifica sha256 (sidecar)"
  (cd "$(dirname "$BACKUP_FILE")" && sha256sum -c --quiet "$(basename "$BACKUP_FILE").sha256") || die "checksum errato"
fi

WORK=$(mktemp -d); trap 'rm -rf -- "$WORK"' EXIT
set +o pipefail   # tar si ferma al primo membro: SIGPIPE sul decompressore è atteso
dec | tar -xf - -C "$WORK" --occurrence=1 meta.tar
set -o pipefail
[[ -s "$WORK/meta.tar" ]] || die "meta.tar non trovato: non è un backup della strategia B?"
tar -xf "$WORK/meta.tar" -C "$WORK"
grep -qvE '^[A-Z_][A-Z0-9_]*=' "$WORK/manifest.env" && die "manifest.env non valido"
# shellcheck disable=SC1090  # le chiavi diventano M_<CHIAVE>
source <(sed 's/^/M_/' "$WORK/manifest.env")
[[ "${M_FORMAT:-}" == sbx-backup-B ]] || die "FORMAT=${M_FORMAT:-?}: non è un backup della strategia B"
M_REL=(); for ((i = 0; i < M_REL_COUNT; i++)); do v="M_REL_$i"; M_REL+=("${!v}"); done
M_WS=();  for ((i = 0; i < ${M_WORKSPACE_COUNT:-0}; i++)); do v="M_WORKSPACE_$i"; M_WS+=("${!v}"); done
M_MCP=(); for ((i = 0; i < ${M_MCPFILE_COUNT:-0}; i++)); do v="M_MCPFILE_$i"; M_MCP+=("${!v}"); done
log "backup del $M_CREATED_AT da $M_SOURCE_HOST ($M_SOURCE_USER, $M_SOURCE_HOME, sbx $M_SBX_VERSION, $M_ARCH)"

mkdir -p "$TARGET_HOME"; TARGET_HOME=$(cd "$TARGET_HOME" && pwd -P)
LIVE_HOME=0; [[ "$TARGET_HOME" == "$(cd "$HOME" && pwd -P)" ]] && LIVE_HOME=1

LOCAL_VER=$("$SBX_BIN" version | awk '{print $3}')
if [[ "$LOCAL_VER" != "$M_SBX_VERSION" ]]; then
  [[ "$CHECK_SBX_VERSION" == 1 ]] && die "sbx locale $LOCAL_VER ≠ backup $M_SBX_VERSION (installa la stessa versione o CHECK_SBX_VERSION=0)"
  warn "sbx locale $LOCAL_VER ≠ backup $M_SBX_VERSION"
fi
if [[ "$(uname -m)" != "$M_ARCH" ]]; then
  [[ "$CHECK_ARCH" == 1 ]] && die "architettura $(uname -m) ≠ $M_ARCH"; warn "architettura diversa"
fi
if [[ "$TARGET_HOME" != "$M_SOURCE_HOME" ]]; then
  [[ "$CHECK_HOME_PATH" == 1 ]] && die "TARGET_HOME=$TARGET_HOME ≠ HOME originale $M_SOURCE_HOME (path assoluti nei DB sbx; CHECK_HOME_PATH=0 per forzare)"
  warn "HOME diversa dall'originale: lo stato potrebbe non funzionare"
fi
[[ "$(id -un)" == "$M_SOURCE_USER" ]] || warn "utente $(id -un) ≠ $M_SOURCE_USER"
if [[ "$CHECK_KVM" == 1 ]]; then [[ -r /dev/kvm && -w /dev/kvm ]] || die "/dev/kvm non accessibile (utente nel gruppo kvm?)"; fi

AVAIL=$(df -B1 --output=avail "$TARGET_HOME" | tail -1 | tr -d ' ')
(( AVAIL > M_STATE_BYTES )) || die "spazio insufficiente in $TARGET_HOME: servono ~$((M_STATE_BYTES >> 20)) MiB"

# ------------------------------ stop daemon locale ---------------------------
if [[ "$LIVE_HOME" == 1 ]] && daemon_running; then
  [[ "$STOP_DAEMON" == 1 ]] || die "daemon sbx attivo sulla HOME di destinazione: serve STOP_DAEMON=1"
  mapfile -t LOCAL_RUN < <("$SBX_BIN" ls --json 2>/dev/null | jq -r '.[] | select(.status=="running") | .name' 2>/dev/null || true)
  confirm "Il daemon sbx locale verrà fermato (sandbox attive: ${LOCAL_RUN[*]:-nessuna}). Procedo?" || die "annullato"
  ((${#LOCAL_RUN[@]})) && "$SBX_BIN" stop "${LOCAL_RUN[@]}"
  "$SBX_BIN" daemon stop || true
  t=0; while daemon_running; do ((t += 2)); ((t > STOP_TIMEOUT)) && die "il daemon non si ferma"; sleep 2; done
fi

# ------------------------------ stato esistente ------------------------------
for r in "${M_REL[@]}"; do
  dst="$TARGET_HOME/$r"
  [[ -e "$dst" && -n "$(ls -A "$dst" 2>/dev/null)" ]] || continue
  case "$EXISTING_STATE" in
    abort) die "esiste già $dst (EXISTING_STATE=move per spostarlo da parte)" ;;
    move)  bak="$dst.pre-restore-$(date +%Y%m%d-%H%M%S)"
           # Punto di mount (es. bind mount del compose sbx): si sposta il contenuto, la cartella resta.
           if command -v mountpoint >/dev/null && mountpoint -q "$dst"; then
             log "sposto il contenuto di $dst (punto di mount) → $bak"; mkdir -p "$bak"
             find "$dst" -mindepth 1 -maxdepth 1 -exec mv -t "$bak" -- {} +
           else
             log "sposto $dst → $bak"; mv -- "$dst" "$bak"
           fi ;;
    *)     die "EXISTING_STATE non valido: $EXISTING_STATE" ;;
  esac
done

# ------------------------------ estrazione -----------------------------------
log "estrazione stato sbx in $TARGET_HOME: ${M_REL[*]}"
dec | tar -C "$TARGET_HOME" -xpf - "${M_REL[@]}"

if ((${#M_WS[@]})) && [[ "$RESTORE_WORKSPACES" != 0 ]]; then
  [[ "$WORKSPACE_ROOT" == / ]] || warn "WORKSPACE_ROOT=$WORKSPACE_ROOT: la spec delle sandbox punta ancora ai path originali"
  mkdir -p "$WORKSPACE_ROOT"
  SEL=()
  for ws in "${M_WS[@]}"; do
    dst="${WORKSPACE_ROOT%/}/${ws#/}"
    if [[ -d "$dst" && -n "$(ls -A "$dst" 2>/dev/null)" && "$WORKSPACE_OVERWRITE" != 1 ]]; then
      warn "workspace $dst non vuoto: salto (WORKSPACE_OVERWRITE=1 per forzare)"
    else SEL+=("${ws#/}"); fi
  done
  if ((${#SEL[@]})); then
    log "estrazione workspace in $WORKSPACE_ROOT: ${SEL[*]}"
    dec | tar -C "$WORKSPACE_ROOT" -xpf - "${SEL[@]}"
  fi
elif [[ "$RESTORE_WORKSPACES" == 1 ]]; then
  die "nessun workspace nel backup"
fi

if ((${#M_MCP[@]})) && [[ "$RESTORE_MCP_HOST_FILES" == 1 ]]; then
  SEL=()
  for p in "${M_MCP[@]}"; do
    if [[ -e "$p" || -L "$p" ]]; then log "file host MCP $p già presente: lasciato com'è"; else SEL+=("${p#/}"); fi
  done
  if ((${#SEL[@]})); then
    log "file host dei server MCP: ${SEL[*]/#//}"
    dec | tar -C / -xpf - "${SEL[@]}" || warn "file host MCP non ripristinati (permessi?): ${SEL[*]}"
  fi
fi

# ------------------------------ credenziali ----------------------------------
if [[ -f "$WORK/secrets.json.gpg" && "$RESTORE_SECRETS" != 0 ]]; then
  need gpg; need python3
  python3 -I -c 'import secretstorage' 2>/dev/null || die "python3-secretstorage mancante (apt install python3-secretstorage) oppure RESTORE_SECRETS=0"
  log "import credenziali nel keyring"
  GPG=(gpg --quiet --decrypt)
  [[ -n "$SECRETS_PASSPHRASE_FILE" ]] && GPG+=(--batch --pinentry-mode loopback --passphrase-file "$SECRETS_PASSPHRASE_FILE")
  "${GPG[@]}" "$WORK/secrets.json.gpg" | python3 -I -c "$PY_IMPORT_SECRETS"
elif [[ "$RESTORE_SECRETS" == 1 ]]; then
  die "credenziali non presenti nel backup"
fi

# ------------------------------ avvio ----------------------------------------
if [[ "$LIVE_HOME" == 1 && "$START_DAEMON_AFTER" == 1 ]]; then
  log "avvio daemon sbx"
  "$SBX_BIN" daemon start --detach >/dev/null 2>&1 || warn "avvio daemon fallito: '$SBX_BIN daemon start --detach'"
  "$SBX_BIN" ls >&2 || true
  if [[ "$START_SANDBOXES_AFTER" == 1 ]]; then
    for s in $M_RUNNING; do log "avvio $s (detached)"; "$SBX_BIN" run -d --name "$s" >/dev/null || warn "avvio $s fallito"; done
  fi
elif [[ "$LIVE_HOME" != 1 ]]; then
  warn "TARGET_HOME non è la HOME reale: daemon non avviato"
fi

log "RESTORE COMPLETATO"
cat >&2 <<EOF

Passi successivi:
  1. sbx login                      (se richiesto: il login Docker non viaggia salvo INCLUDE_DOCKER_LOGIN=1)
  2. sbx ls / sbx secret ls         (verifica sandbox e credenziali)
  3. sbx run --name <sandbox>       (sandbox running al backup: ${M_RUNNING:-nessuna})
  4. Workspace non inclusi nel backup vanno copiati agli stessi path assoluti.
EOF
