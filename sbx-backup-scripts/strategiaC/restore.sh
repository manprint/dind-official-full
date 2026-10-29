#!/usr/bin/env bash
# =============================================================================
#  Strategia C — RESTORE 1:1 di un ambiente compose sbx da un backup di backup.sh
#
#  Ricrea SBX_DATA (Docker del container, home, stato sbx con tutte le sandbox,
#  policy, settings, keyring...) nella cartella SBX_DATA del compose di
#  destinazione, verifica che sia identico all'originale (MANIFEST.txt) e avvia
#  il container. Esegue sull'HOST. I percorsi host possono cambiare: dentro il
#  container restano gli stessi (/home/alpine, /var/lib/docker, workspace).
#
#  Uso:   ./restore.sh /percorso/sbxC-xxx.tar
#         COMPOSE_PROJECT=dind-b SBX_DATA=/srv/b ./restore.sh backup.tar
#  (le variabili del compose — SBX_DATA, SBX_SECRETS_DIR, SBX_WORKSPACE,
#   SBX_WORKSPACE_PATH, DIND_TAG... — si passano come per docker compose:
#   ambiente o file .env accanto al compose)
# =============================================================================
set -Eeuo pipefail

# ============================== CONFIGURAZIONE ===============================
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE="${1:-${ARCHIVE:-}}"                                 # backup da ripristinare
COMPOSE_FILE="${COMPOSE_FILE:-$HERE/../../docker-compose.sbx.bind.yml}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-}"                       # -p del compose (vuoto = default)
SERVICE="${SERVICE:-dind}"
WORK_DIR="${WORK_DIR:-}"                                     # appoggio estrazione; vuoto = accanto a SBX_DATA

EXISTING="${EXISTING:-abort}"                                # SBX_DATA non vuota: abort | move (rinomina in .old-<data>)
RESTORE_WORKSPACE="${RESTORE_WORKSPACE:-1}"                  # workspace.tar (se presente) nel workspace del compose
RESTORE_SECRETS_DIR="${RESTORE_SECRETS_DIR:-1}"              # secrets.tar.gpg → SBX_SECRETS_DIR
SECRETS_PASSPHRASE_FILE="${SECRETS_PASSPHRASE_FILE:-}"       # passphrase gpg da file; vuoto = interattiva
LOAD_IMAGE="${LOAD_IMAGE:-auto}"                             # image.tar: auto (se l'immagine manca) | always | never
VERIFY="${VERIFY:-1}"                                        # confronto 1:1 con MANIFEST.txt
START_AFTER="${START_AFTER:-1}"                              # docker compose up -d alla fine
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"                      # secondi di attesa per lo stato healthy
KEEP_WORK="${KEEP_WORK:-0}"                                  # 1 = non cancellare l'appoggio
# =============================================================================

log()  { printf '\033[1;34m[C-restore]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[C-restore] ATTENZIONE:\033[0m %s\n' "$*" >&2; WARNINGS+=("$*"); }
die()  { printf '\033[1;31m[C-restore] ERRORE:\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "comando mancante: $1"; }
WARNINGS=()

# Stesso elenco 1:1 di backup.sh (deve restare identico).
MANIFEST_SH='
cd "$1"
# Dimensione delle directory esclusa: dipende dalla storia delle voci, non dal contenuto.
find . -type s -prune -o -printf "%p\t%y\t%m\t%U\t%G\t%s\t%T@\t%l\n" | awk -F"\t" -v OFS="\t" "\$2 == \"d\" { \$6 = \"-\" } 1" | LC_ALL=C sort > /tmp/meta
find . -type f -size -64M -print0 | xargs -0 -r -P4 -n200 sha256sum > /tmp/hash
find . -type f -size +64M -print0 | while IFS= read -r -d "" f; do
  h=$(tar --format=gnu --sparse --numeric-owner --owner=0 --group=0 --mode=0000 --mtime=@0 -cf - "$f" | sha256sum | cut -c1-64)
  printf "%s  %s\n" "$h" "$f"
done >> /tmp/hash
LC_ALL=C sort -k2 /tmp/hash > /tmp/hash.sorted
echo "### META"; cat /tmp/meta; echo "### SHA256"; cat /tmp/hash.sorted
echo "### XATTR"
python3 -I - <<"PY"
import hashlib, os, stat
out = []
def emit(p):
    try:
        if stat.S_ISSOCK(os.lstat(p).st_mode): return
        names = os.listxattr(p, follow_symlinks=False)
    except OSError: return
    for n in names:
        try: v = os.getxattr(p, n, follow_symlinks=False)
        except OSError as e: v = ("ERR%d" % e.errno).encode()
        out.append("%s\t%s\t%s" % (p, n, hashlib.sha256(v).hexdigest()[:16]))
emit(".")
for root, dirs, files in os.walk(".", followlinks=False):
    for n in dirs + files: emit(os.path.join(root, n))
print("\n".join(sorted(out)))
PY
'

# ------------------------------ preflight ------------------------------------
for c in docker jq tar sha256sum; do need "$c"; done
[[ -n "$ARCHIVE" && -f "$ARCHIVE" ]] || die "uso: $0 <backup.tar>"
ARCHIVE=$(cd "$(dirname "$ARCHIVE")" && pwd -P)/$(basename "$ARCHIVE")
[[ -f "$COMPOSE_FILE" ]] || die "compose non trovato: $COMPOSE_FILE"
DC=(docker compose -f "$COMPOSE_FILE"); [[ -n "$COMPOSE_PROJECT" ]] && DC+=(-p "$COMPOSE_PROJECT")

tar -xOf "$ARCHIVE" manifest.env > /dev/null 2>&1 || die "manifest.env assente: non è un backup strategia C"
declare -A M=()
while IFS= read -r line; do [[ "$line" == *=* ]] && M[${line%%=*}]=${line#*=}; done < <(tar -xOf "$ARCHIVE" manifest.env)
[[ "${M[FORMAT]:-}" == sbx-backup-C ]] || die "formato ${M[FORMAT]:-?} non supportato"

CFG=$("${DC[@]}" config --format json) || die "docker compose config fallito"
SVC=$(jq -e --arg s "$SERVICE" '.services[$s]' <<<"$CFG") || die "servizio $SERVICE non trovato"
IMAGE=$(jq -r '.image' <<<"$SVC")
CNAME=$(jq -r '.container_name // empty' <<<"$SVC")
src_of() { jq -r --arg t "$1" '.volumes[]? | select(.type == "bind" and .target == $t) | .source' <<<"$SVC"; }
DOCKER_SRC=$(src_of /var/lib/docker); [[ -n "$DOCKER_SRC" ]] || die "nessun bind su /var/lib/docker nel compose"
SBX_DATA=$(dirname "$DOCKER_SRC")
SECRETS_DST=$(src_of /run/secrets/sbx)
WS_TARGET=$(jq -r '.volumes[]? | select(.type == "bind" and (.target | startswith("/home/alpine") | not)
  and .target != "/var/lib/docker" and .target != "/run/secrets/sbx") | .target' <<<"$SVC" | head -1)
WS_DST=""; [[ -n "$WS_TARGET" ]] && WS_DST=$(src_of "$WS_TARGET")

log "backup  : $ARCHIVE (${M[CREATED_AT]} da ${M[SOURCE_HOST]}, sbx ${M[SBX_VERSION]:-?})"
log "target  : ${CNAME:-?} immagine $IMAGE, SBX_DATA = $SBX_DATA"
[[ -n "$("${DC[@]}" ps -aq "$SERVICE" 2>/dev/null)" ]] && die "il container ${CNAME:-$SERVICE} esiste già: docker compose down prima del restore"
if docker container inspect "$CNAME" >/dev/null 2>&1; then die "esiste già un container $CNAME (altro progetto?)"; fi
[[ "${M[WS_TARGET]}" != "$WS_TARGET" ]] && warn "workspace nel container: backup ${M[WS_TARGET]:-<nessuno>}, target ${WS_TARGET:-<nessuno>} — le sandbox registrano il percorso: imposta SBX_WORKSPACE_PATH=${M[WS_TARGET]}"

WORK_DIR="${WORK_DIR:-$(dirname "$SBX_DATA")}"
mkdir -p "$WORK_DIR"
STAGING=$(mktemp -d "$WORK_DIR/.sbxC-restore.XXXXXX")
cleanup() { [[ "$KEEP_WORK" == 1 ]] || rm -rf -- "$STAGING"; }
trap cleanup EXIT

log "estrazione e verifica checksum"
tar -xf "$ARCHIVE" -C "$STAGING"
(cd "$STAGING" && sha256sum --quiet -c SHA256SUMS) || die "checksum non validi: archivio corrotto"
DATA_TAR=$(cd "$STAGING" && ls data.tar* | head -1)
case "$DATA_TAR" in *.zst) need zstd; UNZ="zstd -dc" ;; *.gz) UNZ="gzip -dc" ;; *) UNZ="cat" ;; esac

# ------------------------------ immagine -------------------------------------
IMG_TAR=$(cd "$STAGING" && ls image.tar* 2>/dev/null | head -1 || true)
HAVE_IMAGE=0; docker image inspect "$IMAGE" >/dev/null 2>&1 && HAVE_IMAGE=1
if [[ -n "$IMG_TAR" && ( "$LOAD_IMAGE" == always || ( "$LOAD_IMAGE" == auto && "$HAVE_IMAGE" == 0 ) ) ]]; then
  log "docker load $IMG_TAR"; $UNZ "$STAGING/$IMG_TAR" | docker load >/dev/null
  [[ "$IMAGE" != "${M[IMAGE]}" ]] && docker tag "${M[IMAGE]}" "$IMAGE"
  HAVE_IMAGE=1
fi
if [[ "$HAVE_IMAGE" == 0 ]]; then log "docker pull $IMAGE"; docker pull -q "$IMAGE" >/dev/null || die "immagine $IMAGE non disponibile"; fi
IMG_ID=$(docker image inspect -f '{{.Id}}' "$IMAGE")
[[ -n "${M[IMAGE_ID]}" && "$IMG_ID" != "${M[IMAGE_ID]}" ]] && warn "immagine diversa dall'originale (${M[IMAGE_ID]:0:19} → ${IMG_ID:0:19}): sbx deve restare ${M[SBX_VERSION]:-alla stessa versione}"
TGT_SBX=$(docker run --rm --entrypoint sbx "$IMAGE" version 2>/dev/null | awk '{print $3}')
[[ -n "${M[SBX_VERSION]}" && "$TGT_SBX" != "${M[SBX_VERSION]}" ]] && warn "sbx $TGT_SBX nel target, ${M[SBX_VERSION]} nel backup: un downgrade può rompere il DB del daemon"

# Cartella secret (può essere di root, creata da Docker): letta e scritta dall'helper.
sec() { docker run --rm -i --network none -u 0 --entrypoint bash -v "$SECRETS_DST:/sec" "$IMAGE" -c "$1"; }
helper() {  # $1 = mount extra (--volume=...), resto = comando bash nel container helper (root)
  local vols=("$1"); shift
  docker run --rm --network none -u 0 --cap-add SYS_ADMIN --entrypoint bash -v "$STAGING:/in:ro" "${vols[@]}" "$IMAGE" -c "$@"
}

# ------------------------------ SBX_DATA -------------------------------------
if [[ -d "$SBX_DATA" && -n "$(ls -A "$SBX_DATA" 2>/dev/null)" ]]; then
  case "$EXISTING" in
    move) OLD="$SBX_DATA.old-$(date +%Y%m%d-%H%M%S)"; warn "SBX_DATA non vuota, spostata in $OLD"; mv -- "$SBX_DATA" "$OLD" ;;
    *)    die "SBX_DATA $SBX_DATA non è vuota (EXISTING=move per spostarla)" ;;
  esac
fi
mkdir -p "$SBX_DATA"
log "ripristino SBX_DATA (sparse, owner numerici, xattr/ACL)"
helper "--volume=$SBX_DATA:/dst" "$UNZ /in/$DATA_TAR | tar -C /dst --sparse --numeric-owner --xattrs --xattrs-include='*' --acls -xpf -"

if [[ "$VERIFY" == 1 && -f "$STAGING/MANIFEST.txt" ]]; then
  log "verifica 1:1 (metadati + sha256 di ogni file)"
  helper "--volume=$SBX_DATA:/dst:ro" "$MANIFEST_SH" _ /dst > "$STAGING/MANIFEST.restored.txt"
  # Backup di versioni precedenti: dimensione delle directory ancora presente, si azzera.
  awk -F'\t' -v OFS='\t' 'NF >= 8 && $2 == "d" { $6 = "-" } 1' "$STAGING/MANIFEST.txt" > "$STAGING/MANIFEST.norm" && mv "$STAGING/MANIFEST.norm" "$STAGING/MANIFEST.txt"
  if diff -q "$STAGING/MANIFEST.txt" "$STAGING/MANIFEST.restored.txt" >/dev/null; then
    log "1:1 OK: $(grep -c . "$STAGING/MANIFEST.txt") righe identiche"
  else
    cp "$STAGING/MANIFEST.txt" "$STAGING/MANIFEST.restored.txt" "$WORK_DIR/" 2>/dev/null || true
    diff "$STAGING/MANIFEST.txt" "$STAGING/MANIFEST.restored.txt" | head -20 >&2
    die "SBX_DATA ripristinata NON identica all'originale (manifest in $WORK_DIR)"
  fi
elif [[ "$VERIFY" == 1 ]]; then
  warn "MANIFEST.txt assente nel backup: verifica 1:1 saltata"
fi

# ------------------------------ workspace ------------------------------------
WS_TAR=$(cd "$STAGING" && ls workspace.tar* 2>/dev/null | head -1 || true)
if [[ -n "$WS_TAR" && "$RESTORE_WORKSPACE" == 1 ]]; then
  if [[ -z "$WS_DST" ]]; then warn "backup con workspace ma nessun workspace nel compose: saltato"
  elif [[ -n "$(ls -A "$WS_DST" 2>/dev/null)" ]]; then warn "workspace $WS_DST non vuoto: NON sovrascritto (ripristino manuale da $WS_TAR)"
  else
    log "workspace → $WS_DST"; mkdir -p "$WS_DST"
    helper "--volume=$WS_DST:/dst" "$UNZ /in/$WS_TAR | tar -C /dst --numeric-owner -xpf -"
  fi
fi

# ------------------------------ secrets --------------------------------------
if [[ -f "$STAGING/secrets.tar.gpg" && "$RESTORE_SECRETS_DIR" == 1 ]]; then
  need gpg
  if [[ -z "$SECRETS_DST" ]]; then warn "nessun bind /run/secrets/sbx nel compose: secret non ripristinati"
  elif sec '[ -n "$(ls -A /sec)" ]'; then warn "$SECRETS_DST non vuota: lasciata com'è (deve contenere la password originale del keyring)"
  else
    log "cartella secret → $SECRETS_DST"
    GPG=(gpg --quiet --decrypt)
    [[ -n "$SECRETS_PASSPHRASE_FILE" ]] && GPG+=(--batch --pinentry-mode loopback --passphrase-file "$SECRETS_PASSPHRASE_FILE")
    "${GPG[@]}" "$STAGING/secrets.tar.gpg" | sec 'umask 077 && tar -C /sec --numeric-owner -xpf - && chmod 0700 /sec'
  fi
elif [[ -n "${M[SECRETS_DIR]}" && ! -f "$STAGING/secrets.tar.gpg" ]]; then
  [[ -n "$SECRETS_DST" ]] && sec '[ -s /sec/keyring_pass ]' || warn "password del keyring non nel backup: copia a mano keyring_pass in ${SECRETS_DST:-SBX_SECRETS_DIR}"
fi

# ------------------------------ avvio ----------------------------------------
if [[ "$START_AFTER" == 1 ]]; then
  log "docker compose up -d"
  "${DC[@]}" up -d "$SERVICE" >/dev/null
  CID=$("${DC[@]}" ps -q "$SERVICE")
  deadline=$((SECONDS + HEALTH_TIMEOUT)); st=""
  while (( SECONDS < deadline )); do
    st=$(docker inspect -f '{{.State.Health.Status}}' "$CID" 2>/dev/null || echo none)
    [[ "$st" == healthy || "$st" == unhealthy ]] && break; sleep 3
  done
  [[ "$st" == healthy ]] || warn "container non healthy dopo ${HEALTH_TIMEOUT}s (stato: $st)"
  docker exec "$CID" sbx ls >&2 || true
fi

log "restore completato"
if ((${#WARNINGS[@]})); then
  printf '\033[1;33m[C-restore] %d avvisi:\033[0m\n' "${#WARNINGS[@]}" >&2
  printf '  - %s\n' "${WARNINGS[@]}" >&2
fi
