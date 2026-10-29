#!/usr/bin/env bash
# =============================================================================
#  Strategia A — BACKUP "ricostruzione" di una Docker Sandboxes (sbx)
#
#  Produce UN SOLO file <BACKUP_NAME>.tar con dentro:
#    manifest.env              metadati per il restore (nome, agent, cpu, ram, workspace...)
#    spec.json                 opzioni di creazione (skills, MCP, kit, profilo, dischi),
#                              porte pubblicate, regole policy, MCP caricati con sbx mcp load
#    metadata/                 output leggibili di sbx (solo consultazione)
#    rootfs.tar[.zst]          snapshot rootfs (sbx template save): dati e config degli
#                              agent nel rootfs (~/.codex, ~/.config/opencode, ~/.gemini...)
#    volumes.tar[.zst]         volumi block persistenti del kit, rilevati in automatico
#                              (es. claude: ~/.claude/{projects,sessions,todos,...})
#    agent-config.tar[.zst]    config degli agent che il kit riscrive alla sbx create
#                              (non a un riavvio): rimessa dopo la create
#    dind.tar[.zst]            Docker interno completo (/var/lib/docker: immagini,
#                              container, reti, volumi, build cache)       DIND_MODE=raw
#    dind-images/-volumes.*    solo immagini + volumi (docker save)        DIND_MODE=export
#    global.tar                config sbx globale: settings, registro MCP, skill store,
#                              file host dei server MCP locali (mcp-host-files.tar)
#    workspace-N.tar[.zst]     workspace host (opzionale, INCLUDE_WORKSPACE=1)
#    secrets.json.gpg          credenziali sbx (keyring) + variabili env della sandbox, gpg
#    SHA256SUMS                checksum di ogni pezzo
#
#  Agent supportati: claude, codex, copilot, cursor, devin, docker-agent, droid,
#  gemini, kiro, opencode, shell (e futuri: i volumi sono rilevati da /proc/mounts).
#
#  Volumi si copiano a sandbox accesa; Docker interno (raw) e rootfs richiedono
#  l'arresto: lo script ferma dockerd/la sandbox (solo lei, non il daemon sbx)
#  e la riavvia detached alla fine. Consigliato con agente idle.
#  Uso:   ./backup.sh <sandbox>            (config sotto)
#         SANDBOX_NAME=x BACKUP_DIR=/mnt/usb ./backup.sh
# =============================================================================
set -Eeuo pipefail

# ============================== CONFIGURAZIONE ===============================
# Ogni variabile si può sovrascrivere da ambiente: VAR=valore ./backup.sh
SANDBOX_NAME="${SANDBOX_NAME:-${1:-}}"                      # sandbox da salvare (obbligatoria)
BACKUP_DIR="${BACKUP_DIR:-$HOME/sbx-backups}"               # cartella di destinazione del .tar
STAMP="${STAMP:-$(date +%Y%m%d-%H%M%S)}"
BACKUP_NAME="${BACKUP_NAME:-sbxA-${SANDBOX_NAME}-${STAMP}}" # nome file finale (senza .tar)
TEMPLATE_TAG="${TEMPLATE_TAG:-sbx-backup/${SANDBOX_NAME,,}:${STAMP}}"  # tag immagine rootfs
KEEP_LOCAL_TEMPLATE="${KEEP_LOCAL_TEMPLATE:-0}"             # 1 = lascia il template nello store locale

PERSISTENT_PATHS="${PERSISTENT_PATHS:-auto}"                # auto = volumi block montati nella sandbox (tranne /var/lib/docker);
                                                            # oppure lista esplicita di path assoluti separati da spazio

INCLUDE_ROOTFS="${INCLUDE_ROOTFS:-1}"                       # snapshot rootfs (template)
INCLUDE_PERSISTENT_VOLUMES="${INCLUDE_PERSISTENT_VOLUMES:-1}"  # volumi persistenti del kit (history/sessioni agent)
# File di config che i kit riscrivono alla "sbx create" ma lasciano a un riavvio
# (sbx v0.50.1): senza questo pezzo plugin, MCP utente e impostazioni tornano
# quelli di default. Si salvano quelli presenti; vuoto = nessuno.
AGENT_CONFIG_FILES="${AGENT_CONFIG_FILES-/home/agent/.claude.json /home/agent/.claude/settings.json \
/home/agent/.codex/config.toml /home/agent/.gemini/settings.json /home/agent/.local/share/kiro-cli/data.sqlite3 \
/home/agent/.copilot/config.json /home/agent/.cursor/cli-config.json /home/agent/.factory/settings.json}"
DIND_MODE="${DIND_MODE:-raw}"                               # raw    = /var/lib/docker completo (container, reti, cache: tutto)
                                                            # export = solo immagini taggate + volumi (più piccolo, portabile)
                                                            # none   = niente Docker interno
INCLUDE_DIND_IMAGES="${INCLUDE_DIND_IMAGES:-1}"             # (solo DIND_MODE=export) immagini
INCLUDE_DIND_VOLUMES="${INCLUDE_DIND_VOLUMES:-1}"           # (solo DIND_MODE=export) volumi driver local
INCLUDE_GLOBAL_CONFIG="${INCLUDE_GLOBAL_CONFIG:-1}"         # settings override, registro MCP (sbx mcp), skill store (sbx skills)
INCLUDE_MCP_HOST_FILES="${INCLUDE_MCP_HOST_FILES:-1}"       # file host dei server MCP locali (percorsi assoluti nel comando, es. script)
INCLUDE_WORKSPACE="${INCLUDE_WORKSPACE:-0}"                 # 1 = include i workspace host (possono essere enormi)
WORKSPACE_EXCLUDES="${WORKSPACE_EXCLUDES:-}"                # pattern tar --exclude separati da spazio, es. "node_modules .venv target"

INCLUDE_SECRETS="${INCLUDE_SECRETS:-1}"                     # credenziali sbx della sandbox (keyring) cifrate gpg
INCLUDE_GLOBAL_SECRETS="${INCLUDE_GLOBAL_SECRETS:-1}"       # anche secret globali (sbx secret set -g, OAuth, mcp:*)
INCLUDE_DOCKER_LOGIN="${INCLUDE_DOCKER_LOGIN:-0}"           # anche login Docker Hub di sbx (meglio rifare "sbx login")
INCLUDE_ENV="${INCLUDE_ENV:-1}"                             # variabili "sbx create -e" (valori cifrati con i secret)
SECRETS_PASSPHRASE_FILE="${SECRETS_PASSPHRASE_FILE:-}"      # file con passphrase gpg; vuoto = richiesta interattiva

ASSUME_YES="${ASSUME_YES:-0}"                               # 1 = non chiedere conferma prima dello stop
RESTART_AFTER="${RESTART_AFTER:-1}"                         # 1 = riavvia (detached) la sandbox se era running
DOCKERD_STOP_TIMEOUT="${DOCKERD_STOP_TIMEOUT:-60}"          # secondi di attesa arresto dockerd (DIND_MODE=raw)

COMPRESSOR="${COMPRESSOR:-zstd}"                            # zstd | gzip | none (compressione dei pezzi interni)
COMPRESS_LEVEL="${COMPRESS_LEVEL:-3}"                       # zstd 1-19, gzip 1-9
SBX_BIN="${SBX_BIN:-sbx}"                                   # binario sbx
SBX_STATE_DIR="${SBX_STATE_DIR:-$HOME/.local/state/sandboxes/sandboxes}"   # stato sbx (spec, MCP, skill)
KEEP_STAGING_ON_ERROR="${KEEP_STAGING_ON_ERROR:-0}"         # 1 = non cancellare i file parziali in caso di errore
# =============================================================================

log()  { printf '\033[1;34m[A-backup]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[A-backup] ATTENZIONE:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[A-backup] ERRORE:\033[0m %s\n' "$*" >&2; exit 1; }
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
sx()   { "$SBX_BIN" exec "$SANDBOX_NAME" "$@"; }

case "$COMPRESSOR" in
  zstd) need zstd; EXT=".zst"; compress() { zstd -q -T0 "-${COMPRESS_LEVEL}" -c; } ;;
  gzip) EXT=".gz"
        if command -v pigz >/dev/null 2>&1; then compress() { pigz -c "-${COMPRESS_LEVEL}"; }
        else compress() { gzip -c "-${COMPRESS_LEVEL}"; }; fi ;;
  none) EXT=""; compress() { cat; } ;;
  *)    die "COMPRESSOR non valido: $COMPRESSOR (zstd|gzip|none)" ;;
esac
case "$DIND_MODE" in raw|export|none) ;; *) die "DIND_MODE non valido: $DIND_MODE (raw|export|none)" ;; esac

# Esporta da Secret Service gli item sbx + env della sandbox: JSON su stdout (mai su disco in chiaro).
# Id keyring: docker/sandbox/credentials/<sandbox>/<nome> (scope sandbox), .../credentials/_/<nome>
# e .../credentials/_all/registry:<host> (globali), docker/sandbox/default/<nome> (OAuth globali);
# login: gruppo com.docker.sandboxes-auth.
PY_EXPORT_SECRETS='
import base64, json, sys
name, inc_sec, inc_global, inc_login, spec_file, inc_env = sys.argv[1:7]
items, env = [], {}
if inc_sec == "1":
    import secretstorage
    conn = secretstorage.dbus_init()
    groups = ["com.docker.sandboxes"] + (["com.docker.sandboxes-auth"] if inc_login == "1" else [])
    for g in groups:
        for it in secretstorage.search_items(conn, {"service:group": g}):
            attrs = dict(it.get_attributes())
            sid = attrs.get("id", "")
            if g == "com.docker.sandboxes":
                p = sid.split("/")
                if sid.startswith("docker/sandbox/credentials/") and len(p) > 3 and p[3] not in ("_", "_all"):
                    if p[3] != name:
                        continue                      # secret di altre sandbox
                elif inc_global != "1":
                    continue
            if it.is_locked():
                it.unlock()
            ctype = getattr(it, "get_secret_content_type", lambda: "text/plain")()
            items.append({"label": it.get_label(), "attributes": attrs, "content_type": ctype,
                          "secret": base64.b64encode(it.get_secret()).decode()})
            print("  secret:", sid or it.get_label(), file=sys.stderr)
if inc_env == "1" and spec_file:
    try:
        env = json.load(open(spec_file))["Spec"].get("Environment") or {}
    except (OSError, ValueError, KeyError):
        env = {}
json.dump({"keyring": items, "env": env}, sys.stdout)
print("%d secret, %d variabili env esportati" % (len(items), len(env)), file=sys.stderr)
'

# ------------------------------ preflight ------------------------------------
[[ -n "$SANDBOX_NAME" ]] || die "manca la sandbox: ./backup.sh <nome> oppure SANDBOX_NAME=<nome> ./backup.sh (elenco: sbx ls)"
for c in "$SBX_BIN" tar jq sha256sum; do need "$c"; done
[[ -z "$SECRETS_PASSPHRASE_FILE" || -r "$SECRETS_PASSPHRASE_FILE" ]] || die "SECRETS_PASSPHRASE_FILE non leggibile"

SBX_LS=$("$SBX_BIN" ls --json) || die "sbx ls fallito (daemon attivo?)"
SB_JSON=$(jq -e --arg n "$SANDBOX_NAME" '.[] | select(.name==$n)' <<<"$SBX_LS") \
  || die "sandbox '$SANDBOX_NAME' non trovata (sbx ls)"
AGENT=$(jq -r '.agent' <<<"$SB_JSON")
CPUS=$(jq -r '.cpus // empty' <<<"$SB_JSON")
MEMORY=$(jq -r '.memory // empty' <<<"$SB_JSON")
STATUS=$(jq -r '.status' <<<"$SB_JSON")
mapfile -t WORKSPACES < <(jq -r '.workspaces[]?' <<<"$SB_JSON")
WAS_RUNNING=0; [[ "$STATUS" == running ]] && WAS_RUNNING=1

SPEC_FILE="$SBX_STATE_DIR/sandboxd/runtimes/$SANDBOX_NAME.json"
[[ -r "$SPEC_FILE" ]] || { warn "spec $SPEC_FILE non leggibile: opzioni di creazione ed env non salvati"; SPEC_FILE=""; }
ENV_COUNT=0; [[ -n "$SPEC_FILE" ]] && ENV_COUNT=$(jq '.Spec.Environment // {} | length' "$SPEC_FILE")
[[ "$INCLUDE_ENV" == 1 && "$ENV_COUNT" -gt 0 ]] || INCLUDE_ENV=0
DO_GPG=0; [[ "$INCLUDE_SECRETS" == 1 || "$INCLUDE_ENV" == 1 ]] && DO_GPG=1
if [[ "$DO_GPG" == 1 ]]; then
  need gpg; need python3
  [[ "$INCLUDE_SECRETS" == 1 ]] && { python3 -I -c 'import secretstorage' 2>/dev/null \
    || die "python3-secretstorage mancante (apt install python3-secretstorage) oppure INCLUDE_SECRETS=0"; }
fi
[[ "$ENV_COUNT" -gt 0 && "$INCLUDE_ENV" != 1 ]] && warn "$ENV_COUNT variabili env NON salvate (INCLUDE_ENV=0)"

[[ "$WAS_RUNNING" == 1 ]] || warn "sandbox in stato '$STATUS': sbx exec la avvierà temporaneamente"
if [[ ( "$INCLUDE_ROOTFS" == 1 || "$DIND_MODE" == raw ) && "$ASSUME_YES" != 1 ]]; then
  read -r -p "'$SANDBOX_NAME' verrà fermata per la copia (rootfs/Docker interno) e poi riavviata. Procedo? [si/NO] " ans < /dev/tty
  [[ "$ans" =~ ^(s|si|sì|y|yes)$ ]] || die "annullato dall'utente"
fi

mkdir -p "$BACKUP_DIR"
BACKUP_DIR=$(cd "$BACKUP_DIR" && pwd -P)
ARCHIVE="$BACKUP_DIR/$BACKUP_NAME.tar"
PARTIAL="$ARCHIVE.partial"
STAGING="$BACKUP_DIR/.$BACKUP_NAME.staging"
[[ -e "$ARCHIVE" || -e "$PARTIAL" || -e "$STAGING" ]] && die "esiste già $ARCHIVE (o .partial/.staging)"

ROOT_USED=$(sx df -B1 --output=used / | tail -1 | tr -d ' ') || ROOT_USED=0
AVAIL=$(df -B1 --output=avail "$BACKUP_DIR" | tail -1 | tr -d ' ')
(( AVAIL > ROOT_USED * 2 )) || warn "spazio libero in $BACKUP_DIR ($((AVAIL>>30))G) < 2x rootfs usato ($((ROOT_USED>>30))G): rischio disco pieno"

TEMPLATE_CREATED=0; STOPPED=0; DOCKERD_STOPPED=0
restart_if_needed() {
  [[ "$STOPPED" == 1 && "$WAS_RUNNING" == 1 && "$RESTART_AFTER" == 1 ]] || return 0
  log "riavvio $SANDBOX_NAME (detached)"
  "$SBX_BIN" run -d --name "$SANDBOX_NAME" >/dev/null || warn "riavvio fallito: '$SBX_BIN run --name $SANDBOX_NAME'"
  STOPPED=0
}
cleanup_on_error() {
  local rc=$?
  warn "backup fallito (exit $rc, riga ${BASH_LINENO[0]})"
  if [[ "$KEEP_STAGING_ON_ERROR" != 1 ]]; then rm -rf -- "$STAGING" "$PARTIAL"; else warn "file parziali lasciati in $STAGING"; fi
  [[ "$TEMPLATE_CREATED" == 1 && "$KEEP_LOCAL_TEMPLATE" != 1 ]] && "$SBX_BIN" template rm -f "$TEMPLATE_TAG" >/dev/null 2>&1
  if [[ "$DOCKERD_STOPPED" == 1 && "$STOPPED" != 1 ]]; then   # dockerd fermato: riparte solo con la sandbox
    "$SBX_BIN" stop "$SANDBOX_NAME" >/dev/null 2>&1; STOPPED=1
  fi
  restart_if_needed
  exit "$rc"
}
trap cleanup_on_error ERR

mkdir -p "$STAGING/metadata"
: > "$STAGING/SHA256SUMS"

add_piece() {  # $1 = file o cartella dentro STAGING: checksum, append al tar, rimozione
  local p="$1"
  (cd "$STAGING" && find "$p" -type f -exec sha256sum -- {} + >> SHA256SUMS)
  tar -rf "$PARTIAL" -C "$STAGING" -- "$p"
  rm -rf -- "${STAGING:?}/$p"
}

# ------------------------------ manifest + spec ------------------------------
PPATHS=()
if [[ "$INCLUDE_PERSISTENT_VOLUMES" == 1 ]]; then
  if [[ "$PERSISTENT_PATHS" == auto ]]; then
    mapfile -t PPATHS < <(sx awk '$1 ~ /^\/dev\/vd/ && $2 != "/var/lib/docker" {print $2}' /proc/mounts)
  else
    # shellcheck disable=SC2206  # lista separata da spazi voluta
    PPATHS=($PERSISTENT_PATHS)
  fi
fi
log "sandbox=$SANDBOX_NAME agent=$AGENT cpus=$CPUS mem=$MEMORY ws=${WORKSPACES[*]:-<nessuno>}"
log "volumi persistenti: ${PPATHS[*]:-<nessuno: dati agent solo nel rootfs>}"
{
  printf '%s=%q\n' FORMAT sbx-backup-A FORMAT_VERSION 3 \
    CREATED_AT "$(date -Iseconds)" SOURCE_HOST "$(hostname)" SOURCE_USER "$(id -un)" SOURCE_HOME "$HOME" \
    SBX_VERSION "$("$SBX_BIN" version | awk '{print $3}')" \
    SANDBOX_NAME "$SANDBOX_NAME" AGENT "$AGENT" CPUS "$CPUS" MEMORY "$MEMORY" WAS_RUNNING "$WAS_RUNNING" \
    TEMPLATE_TAG "$TEMPLATE_TAG" PERSISTENT_PATHS "${PPATHS[*]}" DIND_MODE "$DIND_MODE" \
    WORKSPACE_COUNT "${#WORKSPACES[@]}"
  for i in "${!WORKSPACES[@]}"; do printf 'WORKSPACE_%d=%q\n' "$i" "${WORKSPACES[$i]}"; done
} > "$STAGING/manifest.env"
tar -cf "$PARTIAL" -C "$STAGING" manifest.env
(cd "$STAGING" && sha256sum manifest.env >> SHA256SUMS); rm -f "$STAGING/manifest.env"

# spec.json: tutto ciò che serve a ricreare la sandbox con le stesse opzioni (niente valori sensibili)
SPEC_SEL='{}'
[[ -n "$SPEC_FILE" ]] && SPEC_SEL=$(jq '.Spec | {AgentName, WorkspaceDir, AdditionalWorkspaces, CPUs, Memory,
    EnvKeys: (.Environment // {} | keys), MCP, Skills, Profile, RuntimeKits, KitUsage, SourceRepoDir,
    DinDVolumeSize, RootFilesystemSize, ClonedWorkspaceSize, PullPolicy, Template, Labels, Display, GPU,
    PersistentKitVolumes, CredentialSources: (.Credentials.Sources // {} | keys)}' "$SPEC_FILE")
# sbx ports lists them only while running; sandboxd keeps them per sandbox in
# runtimes/ports/<sha256 of the name>.json, readable when stopped too.
PORTS_FILE="$SBX_STATE_DIR/sandboxd/runtimes/ports/$(printf '%s' "$SANDBOX_NAME" | sha256sum | cut -d' ' -f1).json"
if [[ -s "$PORTS_FILE" ]]; then PORTS=$(jq -c '. // []' "$PORTS_FILE")
else PORTS=$("$SBX_BIN" ports "$SANDBOX_NAME" --json 2>/dev/null | jq -c '. // []') || PORTS='[]'; fi
POLICY=$("$SBX_BIN" policy ls "$SANDBOX_NAME" --json 2>/dev/null | jq -c '. // {rules: []}') || POLICY='{"rules":[]}'
# MCP caricati dopo la create (sbx mcp load): non sono nella spec ma nello stato
# del gateway della sandbox.
GW_FILE="$SBX_STATE_DIR/sandboxd/mcp/gateways/$SANDBOX_NAME.json"
MCP_DYN='[]'; [[ -s "$GW_FILE" ]] && MCP_DYN=$(jq -c '.dynamic_added_set // []' "$GW_FILE")
jq -n --argjson spec "$SPEC_SEL" --argjson ports "$PORTS" --argjson policy "$POLICY" --argjson mcpdyn "$MCP_DYN" \
  '{spec: $spec, ports: $ports, policy: $policy, mcp_dynamic: $mcpdyn}' > "$STAGING/spec.json"
add_piece spec.json

M="$STAGING/metadata"
"$SBX_BIN" version                       > "$M/sbx-version.txt" 2>&1 || true
jq . <<<"$SB_JSON"                       > "$M/sandbox.json"
"$SBX_BIN" policy ls "$SANDBOX_NAME"     > "$M/policy.txt"      2>&1 || true
"$SBX_BIN" secret ls                     > "$M/secrets-list.txt" 2>&1 || true   # solo nomi, nessun valore
"$SBX_BIN" ports "$SANDBOX_NAME"         > "$M/ports.txt"       2>&1 || true
"$SBX_BIN" mcp ls                        > "$M/mcp.txt"         2>&1 || true
"$SBX_BIN" skills ls                     > "$M/skills.txt"      2>&1 || true
"$SBX_BIN" settings ls 2>/dev/null | awk 'NR==1 || $4!="default"' > "$M/settings-overrides.txt" || true
sx sh -c 'df -hT; echo; command -v docker >/dev/null && { docker image ls; echo; docker volume ls; echo; docker ps -a; echo; docker network ls; }' \
  > "$M/inside.txt" 2>&1 || true
add_piece metadata

# ------------------------------ volumi persistenti ---------------------------
# Path salvati relativi a /; sudo -n se disponibile (proprietari e file non leggibili), altrimenti utente agent
if ((${#PPATHS[@]})); then
  REL_PATHS=(); for p in "${PPATHS[@]}"; do REL_PATHS+=("${p#/}"); done
  sx sh -c 'S=; sudo -n true 2>/dev/null && S="sudo -n"
            $S tar -C / --exclude=lost+found --numeric-owner -cpf - "$@"; rc=$?
            [ $rc -eq 1 ] && echo "tar: file modificati durante la copia (agente attivo?)" >&2
            [ $rc -le 1 ]' _ "${REL_PATHS[@]}" | compress > "$STAGING/volumes.tar$EXT"
  add_piece "volumes.tar$EXT"
fi

# ------------------------------ config degli agent ---------------------------
if [[ -n "${AGENT_CONFIG_FILES// /}" ]]; then
  # shellcheck disable=SC2086  # lista separata da spazi voluta
  mapfile -t CFG_FILES < <(sx sh -c 'for f; do [ -f "$f" ] && printf "%s\n" "${f#/}"; done; true' _ $AGENT_CONFIG_FILES)
  if ((${#CFG_FILES[@]})); then
    log "config degli agent riscritta dal kit alla create: ${CFG_FILES[*]/#//}"
    sx sh -c 'S=; sudo -n true 2>/dev/null && S="sudo -n"
              $S tar -C / --numeric-owner -cpf - "$@"' _ "${CFG_FILES[@]}" | compress > "$STAGING/agent-config.tar$EXT"
    add_piece "agent-config.tar$EXT"
  fi
fi

# ------------------------------ Docker interno -------------------------------
if [[ "$DIND_MODE" != none ]] && ! sx sh -c 'command -v docker >/dev/null && docker info >/dev/null 2>&1'; then
  warn "Docker interno non disponibile: salto"; DIND_MODE=none
fi
if [[ "$DIND_MODE" == raw ]]; then
  # dockerd fermo → copia coerente di tutto /var/lib/docker (xattr/ACL inclusi); riparte al riavvio della sandbox
  log "Docker interno (raw): stop dockerd e copia /var/lib/docker"
  DOCKERD_STOPPED=1
  sx sudo -n sh -c 'pkill -TERM -x dockerd; i=0
                    while pgrep -x dockerd >/dev/null; do i=$((i+1)); [ $i -gt "$1" ] && exit 9; sleep 1; done
                    tar -C /var/lib/docker --numeric-owner --xattrs --xattrs-include="*" --acls \
                        --exclude=./lost+found -cpf - .' _ "$DOCKERD_STOP_TIMEOUT" \
    | compress > "$STAGING/dind.tar$EXT"
  add_piece "dind.tar$EXT"
  "$SBX_BIN" stop "$SANDBOX_NAME" >/dev/null; STOPPED=1   # dockerd riparte solo con la sandbox
elif [[ "$DIND_MODE" == export ]]; then
  [[ "$(sx docker ps -q | wc -l)" -gt 0 ]] && warn "container attivi nel Docker interno: volumi potenzialmente inconsistenti"
  if [[ "$INCLUDE_DIND_IMAGES" == 1 ]]; then
    mapfile -t IMGS < <(sx docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>' | sort -u)
    if ((${#IMGS[@]})); then
      log "docker save: ${IMGS[*]}"
      sx docker save "${IMGS[@]}" | compress > "$STAGING/dind-images.tar$EXT"
      add_piece "dind-images.tar$EXT"
    else log "nessuna immagine nel Docker interno"; fi
  fi
  if [[ "$INCLUDE_DIND_VOLUMES" == 1 ]]; then
    mapfile -t VOLS < <(sx docker volume ls -q --filter driver=local)
    if ((${#VOLS[@]})); then
      log "volumi docker: ${VOLS[*]}"
      printf '%s\n' "${VOLS[@]}" > "$STAGING/dind-volumes.list"
      VPATHS=(); for v in "${VOLS[@]}"; do VPATHS+=("$v/_data"); done
      sx sudo -n tar -C /var/lib/docker/volumes --numeric-owner -cpf - "${VPATHS[@]}" \
        | compress > "$STAGING/dind-volumes.tar$EXT"
      add_piece dind-volumes.list
      add_piece "dind-volumes.tar$EXT"
    else log "nessun volume nel Docker interno"; fi
  fi
  warn "DIND_MODE=export: container, reti e build cache del Docker interno NON salvati"
fi

# ------------------------------ rootfs (template) ----------------------------
# sbx accetta "template save" solo a sandbox ferma: stop → snapshot → riavvio
if [[ "$INCLUDE_ROOTFS" == 1 ]]; then
  if [[ "$STOPPED" != 1 ]]; then
    log "stop $SANDBOX_NAME per lo snapshot del rootfs"
    "$SBX_BIN" stop "$SANDBOX_NAME" >/dev/null
    STOPPED=1
  fi
  log "template save → $TEMPLATE_TAG (può richiedere vari minuti)"
  "$SBX_BIN" template save "$SANDBOX_NAME" "$TEMPLATE_TAG" -o "$STAGING/rootfs.tar"
  TEMPLATE_CREATED=1
  restart_if_needed
  if [[ -n "$EXT" ]]; then
    log "compressione rootfs ($COMPRESSOR)"
    compress < "$STAGING/rootfs.tar" > "$STAGING/rootfs.tar$EXT"
    rm -f "$STAGING/rootfs.tar"
  fi
  add_piece "rootfs.tar$EXT"
  if [[ "$KEEP_LOCAL_TEMPLATE" != 1 ]]; then
    "$SBX_BIN" template rm -f "$TEMPLATE_TAG" >/dev/null 2>&1 || warn "impossibile rimuovere template locale $TEMPLATE_TAG"
    TEMPLATE_CREATED=0
  fi
elif [[ "$WAS_RUNNING" == 0 ]]; then
  "$SBX_BIN" stop "$SANDBOX_NAME" >/dev/null 2>&1 || true   # era ferma: rimettila com'era
else
  restart_if_needed
fi

# ------------------------------ config sbx globale ---------------------------
# settings override (sbx settings), registro MCP (sbx mcp add), skill store (sbx skills)
if [[ "$INCLUDE_GLOBAL_CONFIG" == 1 ]]; then
  G="$STAGING/global"; mkdir -p "$G"
  "$SBX_BIN" settings ls --json 2>/dev/null \
    | jq '(if type == "array" then . else (.settings // []) end) | map(select(.source == "override") | {key, type, value})' \
    > "$G/settings-overrides.json" || echo '[]' > "$G/settings-overrides.json"
  for d in sandboxd/mcp/servers agent-skills agent-skills-metadata; do
    [[ -d "$SBX_STATE_DIR/$d" ]] || continue
    mkdir -p "$G/$d"; tar -C "$SBX_STATE_DIR/$d" --exclude='*.lock' --exclude='.lock' -cf - . | tar -C "$G/$d" -xf -
  done
  # Un server MCP locale gira sull'host: i file che il suo comando nomina con un
  # percorso assoluto (script, binari fuori dai percorsi di sistema) non sono
  # nello stato sbx e senza di loro "sbx create --static-mcp" fallisce (500).
  if [[ "$INCLUDE_MCP_HOST_FILES" == 1 ]]; then
    mapfile -t MCP_FILES < <(mcp_host_paths "$SBX_STATE_DIR/sandboxd/mcp/servers")
    if ((${#MCP_FILES[@]})); then
      log "file host dei server MCP: ${MCP_FILES[*]}"
      printf '%s\n' "${MCP_FILES[@]}" > "$G/mcp-host-files.txt"
      tar -C / -cpf "$G/mcp-host-files.tar" "${MCP_FILES[@]#/}" || warn "file host MCP non salvati"
    fi
  fi
  log "config globale: $(jq length "$G/settings-overrides.json") settings, $(find "$G/sandboxd/mcp/servers" -name '*.json' 2>/dev/null | wc -l) server MCP, $(find "$G/agent-skills" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l) skill"
  tar -C "$STAGING" -cf "$STAGING/global.tar" global && rm -rf -- "$G"
  add_piece global.tar
fi

# ------------------------------ workspace host -------------------------------
if [[ "$INCLUDE_WORKSPACE" == 1 ]]; then
  for i in "${!WORKSPACES[@]}"; do
    ws="${WORKSPACES[$i]%:ro}"
    [[ -d "$ws" ]] || { warn "workspace $ws non trovato sull'host: salto"; continue; }
    EXCL=(); for p in $WORKSPACE_EXCLUDES; do EXCL+=("--exclude=$p"); done
    wsr=$(cd "$ws" && pwd -P)
    case "$BACKUP_DIR/" in "$wsr/"*) EXCL+=("--exclude=./${BACKUP_DIR#"$wsr"/}") ;; esac
    log "workspace $i: $ws ($(du -sh "$ws" 2>/dev/null | cut -f1))"
    tar -C "$ws" "${EXCL[@]}" -cpf - . | compress > "$STAGING/workspace-$i.tar$EXT"
    add_piece "workspace-$i.tar$EXT"
  done
fi

# ------------------------------ credenziali + env ----------------------------
if [[ "$DO_GPG" == 1 ]]; then
  log "export credenziali/env (cifrati gpg AES256)"
  GPG=(gpg --quiet --symmetric --cipher-algo AES256 --output "$STAGING/secrets.json.gpg")
  [[ -n "$SECRETS_PASSPHRASE_FILE" ]] && GPG+=(--batch --yes --pinentry-mode loopback --passphrase-file "$SECRETS_PASSPHRASE_FILE")
  python3 -I -c "$PY_EXPORT_SECRETS" "$SANDBOX_NAME" "$INCLUDE_SECRETS" "$INCLUDE_GLOBAL_SECRETS" \
    "$INCLUDE_DOCKER_LOGIN" "$SPEC_FILE" "$INCLUDE_ENV" | "${GPG[@]}"
  add_piece secrets.json.gpg
fi

# ------------------------------ chiusura -------------------------------------
tar -rf "$PARTIAL" -C "$STAGING" SHA256SUMS
rm -rf -- "$STAGING"
mv -- "$PARTIAL" "$ARCHIVE"
trap - ERR
log "OK → $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
tar -tf "$ARCHIVE" | grep -v '^metadata/.' | sed 's/^/    /' >&2
