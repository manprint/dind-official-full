#!/usr/bin/env bash
# =============================================================================
#  Strategia A — RESTORE "ricostruzione" di una Docker Sandboxes (sbx)
#
#  Prende il .tar prodotto da backup.sh e ricrea la sandbox:
#     1. verifica checksum                 8. sbx create con le stesse opzioni (cpu, ram,
#     2. ripristina workspace (opz.)          workspace, env, skills, MCP, profilo, disco DinD)
#     3. inizializza la policy se manca     9. ripristina volumi persistenti dell'agent
#     4. config globale: settings,             (es. ~/.claude di claude, + remap path progetti)
#        registro MCP, skill store,            e la config che il kit riscrive alla create
#        file host dei server MCP          10. Docker interno (raw: tutto; export: immagini+volumi)
#     5. importa credenziali (keyring)     11. carica MCP, regole policy, porte pubblicate
#     6. prepara le variabili env          12. riporta la sandbox nello stato originale
#     7. sbx template load (rootfs)
#
#  Agent supportati: claude, codex, copilot, cursor, devin, docker-agent, droid,
#  gemini, kiro, opencode, shell (i dati degli agent senza volumi dedicati stanno
#  nel rootfs). copilot, droid e kiro richiedono git sull'host (kit da repo git).
#  Non cancella né sovrascrive sandbox esistenti: se il nome è già usato, si ferma.
#  Legge i backup di formato 1, 2 e 3.
#  Uso:   ./restore.sh /percorso/sbxA-<nome>-<data>.tar
#         SANDBOX_NAME=nuovo-nome MEMORY=8g ./restore.sh backup.tar
# =============================================================================
set -Eeuo pipefail

# ============================== CONFIGURAZIONE ===============================
# Ogni variabile si può sovrascrivere da ambiente. Vuoto = valore preso dal backup.
BACKUP_FILE="${1:-${BACKUP_FILE:-}}"                        # archivio .tar di backup.sh
SANDBOX_NAME="${SANDBOX_NAME:-}"                            # nome nuova sandbox (vuoto = originale)
AGENT="${AGENT:-}"                                          # agent (vuoto = originale, es. claude)
CPUS="${CPUS:-}"                                            # cpu (vuoto = originale)
MEMORY="${MEMORY:-}"                                        # ram, es. 16g (vuoto = originale; max 75% RAM host)
WORKSPACE="${WORKSPACE:-}"                                  # workspace principale (vuoto = stesso percorso)
DIND_SIZE="${DIND_SIZE:-}"                                  # disco /var/lib/docker, es. 30g (vuoto = originale)
EXTRA_CREATE_ARGS="${EXTRA_CREATE_ARGS:-}"                  # argomenti extra per sbx create, es. "--deny-network x.com"

RESTORE_WORKSPACE="${RESTORE_WORKSPACE:-auto}"              # auto = se presente nel backup | 1 | 0
WORKSPACE_OVERWRITE="${WORKSPACE_OVERWRITE:-0}"             # 1 = estrai anche se la cartella non è vuota
RESTORE_PERSISTENT_VOLUMES="${RESTORE_PERSISTENT_VOLUMES:-${RESTORE_CLAUDE_DIRS:-1}}"  # volumi del kit (RESTORE_CLAUDE_DIRS = vecchio nome)
RESTORE_AGENT_CONFIG="${RESTORE_AGENT_CONFIG:-1}"           # config degli agent che il kit riscrive alla create (plugin, MCP utente...)
REMAP_CLAUDE_PROJECTS="${REMAP_CLAUDE_PROJECTS:-1}"         # rinomina ~/.claude/projects/<vecchio-path> se il workspace cambia
RESTORE_DIND="${RESTORE_DIND:-1}"                           # Docker interno (raw o export, come nel backup)
RESTORE_DIND_IMAGES="${RESTORE_DIND_IMAGES:-1}"             # (backup export) immagini
RESTORE_DIND_VOLUMES="${RESTORE_DIND_VOLUMES:-1}"           # (backup export) volumi
RESTORE_GLOBAL_CONFIG="${RESTORE_GLOBAL_CONFIG:-1}"         # settings, registro MCP, skill store (non sovrascrive l'esistente)
RESTORE_SETTINGS="${RESTORE_SETTINGS:-missing}"             # missing = solo chiavi ancora di default | all | none
RESTORE_POLICY="${RESTORE_POLICY:-1}"                       # regole policy aggiunte a mano o approvate (sandbox)
RESTORE_GLOBAL_POLICY="${RESTORE_GLOBAL_POLICY:-1}"         # anche le regole globali aggiunte (se non già presenti)
POLICY_INIT="${POLICY_INIT:-auto}"                          # se la policy globale manca: auto (= come l'origine) | allow-all | balanced | deny-all
RESTORE_PORTS="${RESTORE_PORTS:-1}"                         # ripubblica le porte (errore = solo avviso, es. porta occupata)
RESTORE_MCP="${RESTORE_MCP:-1}"                             # MCP della sandbox (statici al create, gli altri con sbx mcp load)
RESTORE_SECRETS="${RESTORE_SECRETS:-auto}"                  # auto = se presenti nel backup | 1 | 0
RESTORE_ENV="${RESTORE_ENV:-1}"                             # variabili env della sandbox (dal pacchetto cifrato)
SECRETS_PASSPHRASE_FILE="${SECRETS_PASSPHRASE_FILE:-}"      # file con passphrase gpg; vuoto = richiesta interattiva
FINAL_STATE="${FINAL_STATE:-auto}"                          # auto = come l'origine (running/stopped) | running | stopped
VERIFY_CHECKSUMS="${VERIFY_CHECKSUMS:-1}"                   # verifica SHA256 di ogni pezzo prima di procedere
WORK_DIR="${WORK_DIR:-}"                                    # dir temporanea (vuoto = accanto al backup)
KEEP_WORK_DIR="${KEEP_WORK_DIR:-0}"
READY_TIMEOUT="${READY_TIMEOUT:-180}"                       # secondi di attesa sandbox/docker pronti
SBX_BIN="${SBX_BIN:-sbx}"
SBX_STATE_DIR="${SBX_STATE_DIR:-$HOME/.local/state/sandboxes/sandboxes}"
# =============================================================================

log()  { printf '\033[1;34m[A-restore]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[A-restore] ATTENZIONE:\033[0m %s\n' "$*" >&2; WARNINGS+=("$*"); }
die()  { printf '\033[1;31m[A-restore] ERRORE:\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "comando mancante: $1"; }
WARNINGS=()

# Importa nel keyring gli item esportati (rinomina lo scope sandbox se il nome cambia)
# e scrive le variabili env in un file --env-file (0600). Accetta il formato vecchio (lista).
PY_IMPORT_SECRETS='
import base64, json, os, sys
old, new, do_sec, env_file = sys.argv[1:5]
data = json.load(sys.stdin)
items, env = (data, {}) if isinstance(data, list) else (data.get("keyring", []), data.get("env") or {})
if do_sec == "1" and items:
    import secretstorage
    conn = secretstorage.dbus_init()
    col = secretstorage.get_default_collection(conn)
    if col.is_locked():
        col.unlock()
    for e in items:
        attrs, label = dict(e["attributes"]), e["label"]
        if old != new:
            a, b = "/credentials/%s/" % old, "/credentials/%s/" % new
            attrs = {k: v.replace(a, b) for k, v in attrs.items()}
            label = label.replace(a, b)
        col.create_item(label, attrs, base64.b64decode(e["secret"]), replace=True,
                        content_type=e.get("content_type") or "text/plain")
        print("  importato:", attrs.get("id", label), file=sys.stderr)
    print("%d secret importati" % len(items), file=sys.stderr)
if env_file and env:
    fd = os.open(env_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        for k, v in env.items():
            if "\n" in str(v):
                print("  env %s multilinea: saltata" % k, file=sys.stderr); continue
            f.write("%s=%s\n" % (k, v))
    print("%d variabili env pronte" % len(env), file=sys.stderr)
'

# ------------------------------ preflight ------------------------------------
[[ -n "$BACKUP_FILE" ]] || die "uso: $0 <backup.tar>"
[[ -f "$BACKUP_FILE" ]] || die "file non trovato: $BACKUP_FILE"
BACKUP_FILE=$(cd "$(dirname "$BACKUP_FILE")" && pwd -P)/$(basename "$BACKUP_FILE")
for c in "$SBX_BIN" tar jq sha256sum; do need "$c"; done

MEMBERS=$(tar -tf "$BACKUP_FILE") || die "archivio illeggibile"
member() { grep -m1 -xE "$1(\.zst|\.gz)?" <<<"$MEMBERS" || true; }   # nome reale del pezzo (con estensione)
stream() {   # $1 = membro → stdout decompresso
  case "$1" in
    *.zst) need zstd; tar -xOf "$BACKUP_FILE" "$1" | zstd -dc ;;
    *.gz)  tar -xOf "$BACKUP_FILE" "$1" | gzip -dc ;;
    *)     tar -xOf "$BACKUP_FILE" "$1" ;;
  esac
}

if [[ -z "$WORK_DIR" ]]; then WORK_DIR=$(mktemp -d "$(dirname "$BACKUP_FILE")/.sbxA-restore.XXXXXX")
else mkdir -p "$WORK_DIR"; fi
chmod 700 "$WORK_DIR"
ENV_FILE="$WORK_DIR/sandbox.env"
cleanup() { rm -f -- "$ENV_FILE"; [[ "$KEEP_WORK_DIR" == 1 ]] || rm -rf -- "$WORK_DIR"; }
trap cleanup EXIT
CREATED=0
on_error() {
  local rc=$?
  printf '\033[1;31m[A-restore]\033[0m restore fallito (exit %s, riga %s)\n' "$rc" "${BASH_LINENO[0]}" >&2
  [[ $CREATED == 1 ]] && printf '  sandbox %s creata ma incompleta: verifica o rimuovi con: %s rm %s\n' "$SANDBOX_NAME" "$SBX_BIN" "$SANDBOX_NAME" >&2
  exit "$rc"
}
trap on_error ERR

tar -xf "$BACKUP_FILE" -C "$WORK_DIR" manifest.env SHA256SUMS
grep -qvE '^[A-Z_][A-Z0-9_]*=' "$WORK_DIR/manifest.env" && die "manifest.env non valido"
# shellcheck disable=SC1090  # le chiavi diventano M_<CHIAVE>
source <(sed 's/^/M_/' "$WORK_DIR/manifest.env")
[[ "${M_FORMAT:-}" == sbx-backup-A ]] || die "non è un backup della strategia A (FORMAT=${M_FORMAT:-?})"
[[ "${M_FORMAT_VERSION:-1}" =~ ^[123]$ ]] || die "formato backup $M_FORMAT_VERSION non supportato: aggiorna restore.sh"

SPEC='{}'
if [[ -n "$(member 'spec\.json')" ]]; then SPEC=$(tar -xOf "$BACKUP_FILE" spec.json); fi
spec() { jq -r "$1" <<<"$SPEC"; }

SANDBOX_NAME="${SANDBOX_NAME:-$M_SANDBOX_NAME}"
AGENT="${AGENT:-$M_AGENT}"
CPUS="${CPUS:-$M_CPUS}"
MEMORY="${MEMORY:-$M_MEMORY}"
DIND_SIZE="${DIND_SIZE:-$(spec '.spec.DinDVolumeSize // empty')}"
WS_OLD=(); for ((i = 0; i < ${M_WORKSPACE_COUNT:-0}; i++)); do v="M_WORKSPACE_$i"; WS_OLD+=("${!v}"); done
WS_NEW=("${WS_OLD[@]}")
[[ -n "$WORKSPACE" ]] && { ((${#WS_NEW[@]})) && WS_NEW[0]="$WORKSPACE" || WS_NEW=("$WORKSPACE"); }

case "$AGENT" in   # questi kit vengono scaricati da un repo git al create
  copilot|droid|kiro) command -v git >/dev/null 2>&1 || die "l'agent $AGENT richiede git sull'host: installalo (apt install git)" ;;
esac

LOCAL_VER=$("$SBX_BIN" version | awk '{print $3}')
[[ "$LOCAL_VER" == "$M_SBX_VERSION" ]] || warn "versione sbx diversa: backup $M_SBX_VERSION, locale $LOCAL_VER"
"$SBX_BIN" ls --json | jq -e --arg n "$SANDBOX_NAME" 'any(.[]; .name == $n)' >/dev/null \
  && die "esiste già una sandbox '$SANDBOX_NAME': scegli SANDBOX_NAME=altro o rimuovila tu"

log "backup del $M_CREATED_AT da $M_SOURCE_HOST (sbx $M_SBX_VERSION, formato ${M_FORMAT_VERSION:-1})"
log "→ sandbox=$SANDBOX_NAME agent=$AGENT cpus=$CPUS mem=$MEMORY ws=${WS_NEW[*]:-<nessuno>}"

if [[ "$VERIFY_CHECKSUMS" == 1 ]]; then
  log "verifica checksum"
  while read -r sum path; do
    [[ "$(tar -xOf "$BACKUP_FILE" "$path" | sha256sum | cut -d' ' -f1)" == "$sum" ]] || die "checksum errato: $path"
  done < "$WORK_DIR/SHA256SUMS"
fi

# ------------------------------ workspace ------------------------------------
for i in "${!WS_NEW[@]}"; do
  ws="${WS_NEW[$i]%:ro}"; piece=$(member "workspace-$i\.tar")
  if [[ -n "$piece" && "$RESTORE_WORKSPACE" != 0 ]]; then
    if [[ -d "$ws" && -n "$(ls -A "$ws" 2>/dev/null)" && "$WORKSPACE_OVERWRITE" != 1 ]]; then
      warn "workspace $ws non vuoto: non estraggo (WORKSPACE_OVERWRITE=1 per forzare)"
    else
      log "estrazione workspace $i → $ws"
      mkdir -p "$ws"; stream "$piece" | tar -C "$ws" -xpf -
    fi
  elif [[ "$RESTORE_WORKSPACE" == 1 ]]; then
    die "workspace-$i non presente nel backup"
  fi
  [[ -d "$ws" ]] || { warn "workspace $ws assente: lo creo vuoto (copia i dati a parte)"; mkdir -p "$ws"; }
done

# ------------------------------ policy globale -------------------------------
# Su un'installazione nuova la policy globale non esiste e sbx create fallisce
if ! "$SBX_BIN" policy ls --json 2>/dev/null | jq -e '.rules | any(.provenance.created_via == "default")' >/dev/null 2>&1; then
  if [[ "$POLICY_INIT" == auto ]]; then
    POLICY_INIT=$(spec '[.policy.rules[]? | select(.provenance.created_via == "default" and .scope == "global" and .resource_type == "network")]
      | if any(.decision == "allow" and (.resources | index("**"))) then "allow-all"
        elif any(.decision == "deny" and (.resources | index("**"))) then "deny-all"
        elif length > 0 then "balanced" else empty end')
  fi
  if [[ -n "$POLICY_INIT" && "$POLICY_INIT" != auto ]]; then
    log "policy globale assente: sbx policy init $POLICY_INIT (come l'origine)"
    "$SBX_BIN" policy init "$POLICY_INIT"
  else
    warn "policy globale non inizializzata e origine sconosciuta: esegui 'sbx policy init <allow-all|balanced|deny-all>'"
  fi
fi

# ------------------------------ config sbx globale ---------------------------
GLOBAL_PIECE=$(member 'global\.tar')
if [[ -n "$GLOBAL_PIECE" && "$RESTORE_GLOBAL_CONFIG" == 1 ]]; then
  G="$WORK_DIR/g"; mkdir -p "$G"; tar -xOf "$BACKUP_FILE" "$GLOBAL_PIECE" | tar -C "$G" -xf -
  if [[ "$RESTORE_SETTINGS" != none && -s "$G/global/settings-overrides.json" ]]; then
    CUR=$("$SBX_BIN" settings ls --json 2>/dev/null | jq -c 'if type == "array" then . else (.settings // []) end') || CUR='[]'
    while IFS=$'\t' read -r key val; do
      src=$(jq -r --arg k "$key" '.[] | select(.key == $k) | .source' <<<"$CUR")
      cur=$(jq -r --arg k "$key" '.[] | select(.key == $k) | .value | if type == "string" then . else tojson end' <<<"$CUR")
      [[ "$src" == override && "$cur" == "$val" ]] && continue   # già uguale (es. restore precedente)
      if [[ "$RESTORE_SETTINGS" == missing && "$src" == override ]]; then
        warn "setting $key già personalizzato qui: lasciato com'è (origine: $val)"; continue
      fi
      log "setting $key = $val"; "$SBX_BIN" settings set "$key" "$val" >/dev/null || warn "setting $key non applicato"
    done < <(jq -r '.[] | [.key, (if (.value | type) == "string" then .value else (.value | tojson) end)] | @tsv' \
               "$G/global/settings-overrides.json")
  fi
  # File host dei server MCP locali: solo quelli che qui mancano.
  if [[ -s "$G/global/mcp-host-files.tar" && -s "$G/global/mcp-host-files.txt" ]]; then
    while IFS= read -r m; do
      [[ -e "$m" || -L "$m" ]] && continue
      mkdir -p "$(dirname "$m")" 2>/dev/null || true
      if tar -C / -xpf "$G/global/mcp-host-files.tar" "${m#/}" 2>/dev/null; then log "file host MCP ripristinato: $m"
      else warn "file host MCP $m non ripristinato (permessi?)"; fi
    done < "$G/global/mcp-host-files.txt"
  fi
  MCPD="$SBX_STATE_DIR/sandboxd/mcp/servers"
  for f in "$G"/global/sandboxd/mcp/servers/*.json; do
    [[ -e "$f" ]] || continue
    n=$(basename "$f" .json)
    if [[ -e "$MCPD/$n.json" ]]; then log "server MCP $n già registrato: lasciato com'è"; continue; fi
    mkdir -p "$MCPD"; cp -p -- "$f" "$MCPD/"; log "server MCP registrato: $n"
    cmd=$(jq -r '.spec.ResolvedCommand // empty' "$f")
    [[ -z "$cmd" || -x "$cmd" ]] || warn "server MCP $n: comando host $cmd assente su questo PC"
    jq -r '.spec.Command[1:][]? // empty' "$f" | while read -r a; do
      [[ "$a" != /* || -e "$a" ]] || warn "server MCP $n: file host $a assente su questo PC"
    done
  done
  for d in agent-skills agent-skills-metadata; do
    [[ -d "$G/global/$d" ]] || continue
    # sbx crea lo store 700: mkdir da solo lo lascerebbe 755
    if [[ ! -d "$SBX_STATE_DIR/$d" ]]; then
      mkdir -p "$SBX_STATE_DIR/$d" && chmod --reference="$G/global/$d" "$SBX_STATE_DIR/$d"
    fi
    for s in "$G/global/$d"/* "$G/global/$d"/.[!.]*; do
      [[ -e "$s" ]] || continue
      b=$(basename "$s")
      if [[ -e "$SBX_STATE_DIR/$d/$b" ]]; then [[ "$d" == agent-skills ]] && log "skill $b già presente: lasciata com'è"; continue; fi
      cp -a -- "$s" "$SBX_STATE_DIR/$d/"; [[ "$d" == agent-skills ]] && log "skill importata: $b"
    done
  done
fi

# ------------------------------ credenziali + env ----------------------------
SECRETS_PIECE=$(member 'secrets\.json\.gpg')
HAVE_ENV=0
if [[ -n "$SECRETS_PIECE" && ( "$RESTORE_SECRETS" != 0 || "$RESTORE_ENV" == 1 ) ]]; then
  need gpg; need python3
  DO_SEC=0; [[ "$RESTORE_SECRETS" != 0 ]] && DO_SEC=1
  [[ $DO_SEC == 1 ]] && { python3 -I -c 'import secretstorage' 2>/dev/null \
    || die "python3-secretstorage mancante (apt install python3-secretstorage) oppure RESTORE_SECRETS=0"; }
  EF=""; [[ "$RESTORE_ENV" == 1 ]] && EF="$ENV_FILE"
  log "import credenziali nel keyring / variabili env (prima della create, così la sandbox le vede)"
  GPG=(gpg --quiet --decrypt)
  [[ -n "$SECRETS_PASSPHRASE_FILE" ]] && GPG+=(--batch --pinentry-mode loopback --passphrase-file "$SECRETS_PASSPHRASE_FILE")
  tar -xOf "$BACKUP_FILE" "$SECRETS_PIECE" | "${GPG[@]}" \
    | python3 -I -c "$PY_IMPORT_SECRETS" "$M_SANDBOX_NAME" "$SANDBOX_NAME" "$DO_SEC" "$EF"
  [[ -s "$ENV_FILE" ]] && HAVE_ENV=1
elif [[ "$RESTORE_SECRETS" == 1 ]]; then
  die "credenziali non presenti nel backup"
fi
EXPECTED_ENV=$(spec '.spec.EnvKeys // [] | length')
[[ "$EXPECTED_ENV" -gt 0 && "$HAVE_ENV" == 0 ]] && warn "la sandbox originale aveva $EXPECTED_ENV variabili env: non ripristinate ($(spec '.spec.EnvKeys | join(" ")'))"

# ------------------------------ rootfs (template) ----------------------------
TAG=""
ROOTFS_PIECE=$(member 'rootfs\.tar')
if [[ -n "$ROOTFS_PIECE" ]]; then
  log "estrazione rootfs ($ROOTFS_PIECE)"
  stream "$ROOTFS_PIECE" > "$WORK_DIR/rootfs.tar"
  log "sbx template load (può richiedere vari minuti)"
  "$SBX_BIN" template load "$WORK_DIR/rootfs.tar"
  rm -f "$WORK_DIR/rootfs.tar"
  TAG="$M_TEMPLATE_TAG"
else
  warn "rootfs non presente: uso l'immagine standard dell'agent"
fi

# ------------------------------ create ---------------------------------------
MCP_SERVERS=(); [[ "$RESTORE_MCP" == 1 ]] && mapfile -t MCP_SERVERS < <(spec '.spec.MCP.Servers // [] | .[]')
MCP_STATIC=$(spec '.spec.MCP.Static // false')
SKILLS_MODE=$(spec '.spec.Skills // empty'); PROFILE=$(spec '.spec.Profile // empty')
CLONE=$(spec '.spec.SourceRepoDir // empty')
KITS=$(spec '[.spec.RuntimeKits // [] | .[]?] | length')
[[ "$KITS" -gt 0 ]] && warn "la sandbox usava kit aggiuntivi: $(spec '.spec.RuntimeKits | tojson') — riaggiungili con 'sbx kit add' se mancano"

ARGS=(create --name "$SANDBOX_NAME" --no-progress)
[[ -n "$TAG" ]] && ARGS+=(--pull never -t "$TAG")
[[ -n "$CPUS" ]] && ARGS+=(--cpus "$CPUS")
[[ -n "$MEMORY" ]] && ARGS+=(-m "$MEMORY")
[[ "$HAVE_ENV" == 1 ]] && ARGS+=(--env-file "$ENV_FILE")
[[ -n "$SKILLS_MODE" ]] && ARGS+=(--skills "$SKILLS_MODE")
[[ -n "$PROFILE" ]] && ARGS+=(--profile "$PROFILE")
[[ -n "$CLONE" ]] && ARGS+=(--clone)
[[ "$MCP_STATIC" == true && ${#MCP_SERVERS[@]} -gt 0 ]] && ARGS+=(--static-mcp "$(IFS=,; echo "${MCP_SERVERS[*]}")")
# shellcheck disable=SC2206  # split voluto
ARGS+=($EXTRA_CREATE_ARGS "$AGENT" "${WS_NEW[@]}")
log "$SBX_BIN ${ARGS[*]}${DIND_SIZE:+  (disco DinD $DIND_SIZE)}"
create() {
  if [[ -n "$DIND_SIZE" ]]; then DOCKER_SANDBOXES_DOCKER_SIZE="$DIND_SIZE" "$SBX_BIN" "$@"
  else "$SBX_BIN" "$@"; fi
}
MCP_DEFERRED=0
if ! create "${ARGS[@]}"; then
  # Un server MCP statico che sull'host non parte (comando o file mancanti) fa
  # fallire la create con 500: si ricrea senza e lo si carica dopo, con avviso.
  i=$(printf '%s\n' "${ARGS[@]}" | grep -nx -- --static-mcp | cut -d: -f1) || i=""
  [[ -n "$i" ]] || die "sbx create fallita"
  "$SBX_BIN" ls --json 2>/dev/null | jq -e --arg n "$SANDBOX_NAME" 'any(.[]; .name == $n)' >/dev/null \
    && die "sbx create fallita e la sandbox $SANDBOX_NAME esiste: controlla e rimuovila tu"
  warn "sbx create fallita con --static-mcp ${ARGS[$i]}: la ricreo senza MCP statici e li carico dopo con sbx mcp load"
  ARGS=("${ARGS[@]:0:$((i - 1))}" "${ARGS[@]:$((i + 1))}")
  create "${ARGS[@]}"
  MCP_DEFERRED=1
fi
CREATED=1
rm -f -- "$ENV_FILE"

sx()  { "$SBX_BIN" exec "$SANDBOX_NAME" "$@"; }
sxi() { "$SBX_BIN" exec -i "$SANDBOX_NAME" "$@"; }
wait_for() {  # $1 = descrizione, resto = comando nella sandbox
  local what=$1; shift; local t=0
  until sx "$@" >/dev/null 2>&1; do
    ((t += 3)); ((t > READY_TIMEOUT)) && die "timeout in attesa di: $what"; sleep 3
  done
}
wait_for "sandbox pronta" true

# ------------------------------ volumi persistenti ---------------------------
CDIR=""   # cartella ~/.claude da rimappare (solo agent claude)
VOL_PIECE=$(member 'volumes\.tar'); LEGACY_PIECE=$(member 'claude-dirs\.tar')
if [[ "$RESTORE_PERSISTENT_VOLUMES" == 1 && -n "$VOL_PIECE" ]]; then
  log "ripristino volumi persistenti: ${M_PERSISTENT_PATHS:-?}"
  stream "$VOL_PIECE" | sxi sh -c 'S=; sudo -n true 2>/dev/null && S="sudo -n"
                                   $S tar -C / --numeric-owner -xpf -'
  for p in ${M_PERSISTENT_PATHS:-}; do [[ "$p" == */.claude/projects ]] && CDIR=${p%/projects}; done
elif [[ "$RESTORE_PERSISTENT_VOLUMES" == 1 && -n "$LEGACY_PIECE" ]]; then   # backup formato 1
  CDIR="${M_SANDBOX_CLAUDE_DIR:-/home/agent/.claude}"
  log "ripristino volumi Claude in $CDIR"
  stream "$LEGACY_PIECE" | sxi tar -C "$CDIR" -xpf -
fi
# La create ha riscritto questi file con i default del kit; un riavvio li
# lascerebbe come sono: si rimettono quelli dell'origine (il kit li aggiorna
# al prossimo avvio come farebbe con la sandbox originale).
CFG_PIECE=$(member 'agent-config\.tar')
if [[ "$RESTORE_AGENT_CONFIG" == 1 && -n "$CFG_PIECE" ]]; then
  log "config degli agent: $(stream "$CFG_PIECE" | tar -tf - | sed 's#^#/#' | tr '\n' ' ')"
  stream "$CFG_PIECE" | sxi sh -c 'S=; sudo -n true 2>/dev/null && S="sudo -n"
                                   $S tar -C / --numeric-owner -xpf -'
fi
if [[ -n "$CDIR" && "$REMAP_CLAUDE_PROJECTS" == 1 && ${#WS_OLD[@]} -gt 0 && "${WS_OLD[0]}" != "${WS_NEW[0]}" ]]; then
  enc() { printf '%s' "${1%:ro}" | sed 's/[^A-Za-z0-9]/-/g'; }   # stessa codifica usata da Claude Code
  log "remap progetti Claude: $(enc "${WS_OLD[0]}") → $(enc "${WS_NEW[0]}")"
  sx sh -c 'cd "$1/projects" 2>/dev/null || exit 0
            for d in ./"$2" ./"$2"-*; do [ -d "$d" ] || continue; t="./$3${d#./"$2"}"
              if [ -e "$t" ]; then echo "  salto $d: $t esiste" >&2; else mv -- "$d" "$t" && echo "  $d -> $t" >&2; fi
            done' _ "$CDIR" "$(enc "${WS_OLD[0]}")" "$(enc "${WS_NEW[0]}")"
  warn "workspace cambiato: le impostazioni per-progetto in ~/.claude.json restano sul vecchio path"
fi

# ------------------------------ Docker interno -------------------------------
NEED_RESTART=0
RAW_PIECE=$(member 'dind\.tar')
IMG_PIECE=$(member 'dind-images\.tar'); DVOL_PIECE=$(member 'dind-volumes\.tar')
if [[ "$RESTORE_DIND" == 1 && -n "$RAW_PIECE" ]]; then
  # dockerd fermo → sostituzione completa di /var/lib/docker; riparte con la sandbox
  log "Docker interno (raw): sostituisco /var/lib/docker"
  stream "$RAW_PIECE" | sxi sudo -n sh -c 'pkill -TERM -x dockerd; i=0
      while pgrep -x dockerd >/dev/null; do i=$((i+1)); [ $i -gt 60 ] && exit 9; sleep 1; done
      find /var/lib/docker -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf {} +
      tar -C /var/lib/docker --numeric-owner --xattrs --xattrs-include="*" --acls -xpf -'
  NEED_RESTART=1
elif [[ "$RESTORE_DIND" == 1 && ( ( -n "$IMG_PIECE" && "$RESTORE_DIND_IMAGES" == 1 ) || ( -n "$DVOL_PIECE" && "$RESTORE_DIND_VOLUMES" == 1 ) ) ]]; then
  wait_for "Docker interno" docker info
  if [[ -n "$IMG_PIECE" && "$RESTORE_DIND_IMAGES" == 1 ]]; then
    log "docker load"; stream "$IMG_PIECE" | sxi docker load
  fi
  if [[ -n "$DVOL_PIECE" && "$RESTORE_DIND_VOLUMES" == 1 ]]; then
    mapfile -t VOLS < <(tar -xOf "$BACKUP_FILE" dind-volumes.list)
    log "volumi docker: ${VOLS[*]}"
    for v in "${VOLS[@]}"; do sx docker volume create "$v" >/dev/null; done
    stream "$DVOL_PIECE" | sxi sudo -n tar -C /var/lib/docker/volumes --numeric-owner -xpf -
  fi
fi
if [[ "$NEED_RESTART" == 1 ]]; then
  "$SBX_BIN" stop "$SANDBOX_NAME" >/dev/null
  wait_for "Docker interno" docker info
fi

# ------------------------------ MCP, policy, porte ---------------------------
MCP_LOAD=()
[[ "$MCP_STATIC" != true || "$MCP_DEFERRED" == 1 ]] && MCP_LOAD=("${MCP_SERVERS[@]}")
if [[ "$RESTORE_MCP" == 1 ]]; then   # caricati con sbx mcp load sull'origine (backup formato 3)
  while IFS= read -r n; do
    [[ -n "$n" && " ${MCP_LOAD[*]} " != *" $n "* ]] && MCP_LOAD+=("$n")
  done < <(spec '.mcp_dynamic // [] | .[]')
fi
for n in "${MCP_LOAD[@]}"; do
  log "sbx mcp load $n"; "$SBX_BIN" mcp load "$n" --sandbox "$SANDBOX_NAME" >/dev/null || warn "MCP $n non caricato"
done

if [[ "$RESTORE_POLICY" == 1 ]]; then
  # Una riga JSON per regola: [scope, decisione, risorsa, opzioni...]. Le regole di filesystem non si ricreano da CLI.
  CUR_POL=$("$SBX_BIN" policy ls "$SANDBOX_NAME" --json 2>/dev/null) || CUR_POL='{"rules":[]}'
  while read -r row; do
    mapfile -t R < <(jq -r '.[]' <<<"$row")
    scope=${R[0]}; dec=${R[1]}; opts=("${R[@]:2}")
    sel=(); if [[ "$scope" == sandbox:* ]]; then sel=(--sandbox "$SANDBOX_NAME")
    else
      [[ "$RESTORE_GLOBAL_POLICY" == 1 ]] || continue
      jq -e --arg d "$dec" --arg r "${opts[0]}" 'any(.rules[]?; .scope == "global" and .decision == $d
          and .provenance.created_via != "default" and ((.resources // []) | join(",")) == $r)' <<<"$CUR_POL" >/dev/null \
        && { log "regola globale $dec ${opts[0]} già presente"; continue; }
    fi
    log "policy $dec ${sel[*]} ${opts[*]}"
    "$SBX_BIN" policy "$dec" network "${sel[@]}" "${opts[@]}" >/dev/null || warn "regola non applicata: $dec ${opts[*]}"
  done < <(spec '.policy.rules[]? | select(.provenance.created_via == "added" or .provenance.created_via == "approval")
      | select(.scope == "global" or (.scope | startswith("sandbox:"))) | . as $r
      | if .resource_type == "network" then
          ([.actions[]? | select(startswith("net:connect:")) | sub("net:connect:"; "")] | join(",")) as $p
          | [.scope, .decision, (.resources | join(","))] + (if $p == "" then [] else ["--protocol", $p] end) | tojson
        elif .resource_type == "http" then
          (.http_targets[]? | [$r.scope, $r.decision, .host, "--method", ($r.methods | join(",")), "--path", (.path // "/**")]
            + [.query[]? | "--query", "\(.name)=\(.value_pattern)"] | tojson)
        else empty end')
  spec '.policy.rules[]? | select(.provenance.created_via == "added" and (.resource_type | startswith("filesystem")))
        | "\(.decision) \(.resource_type) \(.resources | join(","))"' | while read -r l; do
    warn "regola filesystem non ricreabile da CLI: $l"; done
fi

if [[ "$RESTORE_PORTS" == 1 ]]; then
  while read -r p; do
    log "porta $p"; "$SBX_BIN" ports "$SANDBOX_NAME" --publish "$p" >/dev/null || warn "porta $p non pubblicata (occupata?)"
  done < <(spec '.ports[]? | (if (.host_ip | contains(":")) then "[\(.host_ip)]" else .host_ip end)
                 + ":\(.host_port):\(.sandbox_port)/\(.protocol)"')   # tcp4/tcp6/udp4/udp6 compresi
fi

# ------------------------------ stato finale ---------------------------------
[[ "$FINAL_STATE" == auto ]] && { [[ "${M_WAS_RUNNING:-0}" == 1 ]] && FINAL_STATE=running || FINAL_STATE=stopped; }
if [[ "$FINAL_STATE" == stopped ]]; then "$SBX_BIN" stop "$SANDBOX_NAME" >/dev/null
else "$SBX_BIN" run -d --name "$SANDBOX_NAME" >/dev/null || warn "avvio detached fallito"; fi

# ------------------------------ riepilogo ------------------------------------
trap - ERR
tar -xf "$BACKUP_FILE" -C "$WORK_DIR" metadata 2>/dev/null || true
log "RESTORE COMPLETATO: sandbox '$SANDBOX_NAME' ($FINAL_STATE)"
{
  echo
  echo "Da controllare:"
  echo "  - credenziali:  $SBX_BIN secret ls      (origine: metadata/secrets-list.txt nel backup)"
  echo "  - policy/porte: $SBX_BIN policy ls $SANDBOX_NAME ; $SBX_BIN ports $SANDBOX_NAME"
  echo "  - MCP/skill:    $SBX_BIN mcp ls ; $SBX_BIN skills ls"
  echo "  - avvio agente: $SBX_BIN run --name $SANDBOX_NAME"
  if ((${#WARNINGS[@]})); then echo; echo "Avvisi:"; printf '  - %s\n' "${WARNINGS[@]}"; fi
} >&2
