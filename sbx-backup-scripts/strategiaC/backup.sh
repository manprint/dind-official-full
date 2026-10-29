#!/usr/bin/env bash
# =============================================================================
#  Strategia C — BACKUP "a freddo" 1:1 di un ambiente compose sbx
#                (docker-compose.sbx.bind.yml di dind-env-official)
#
#  Ferma il container (docker compose stop: prima le sandbox, poi sbx e dockerd),
#  copia TUTTA la cartella SBX_DATA (Docker del container, home, stato sbx con le
#  sandbox, policy, settings, keyring...) e lo riavvia. Esegue sull'HOST.
#  La copia la fa un container usa-e-getta dell'immagine stessa, come root:
#  /var/lib/docker contiene file di root, l'utente host non li leggerebbe.
#
#  Output: UN SOLO file <BACKUP_NAME>.tar con dentro:
#    manifest.env        progetto, immagine, percorsi, versioni
#    compose.json        configurazione compose risolta (consultazione)
#    data.tar[.zst]      SBX_DATA completo (sparse, owner numerici, xattr, ACL)
#    workspace.tar[.zst] workspace, se fuori da SBX_DATA e INCLUDE_WORKSPACE=1
#    secrets.tar.gpg     cartella SBX_SECRETS_DIR (password del keyring), cifrata
#    image.tar[.zst]     immagine del container (docker save), se INCLUDE_IMAGE=1
#    MANIFEST.txt        elenco 1:1 (metadati + sha256 di ogni file) per la verifica
#    SHA256SUMS
#
#  Uso:   ./backup.sh                                (config sotto)
#         COMPOSE_PROJECT=dind-b SBX_DATA=/srv/b ./backup.sh
# =============================================================================
set -Eeuo pipefail

# ============================== CONFIGURAZIONE ===============================
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$HERE/../../docker-compose.sbx.bind.yml}"  # compose dell'ambiente
COMPOSE_PROJECT="${COMPOSE_PROJECT:-}"                       # -p del compose (vuoto = default)
SERVICE="${SERVICE:-dind}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/sbx-backups}"
STAMP="${STAMP:-$(date +%Y%m%d-%H%M%S)}"
BACKUP_NAME="${BACKUP_NAME:-}"                               # vuoto = sbxC-<container>-<data>

INCLUDE_WORKSPACE="${INCLUDE_WORKSPACE:-1}"                  # workspace se fuori da SBX_DATA (dentro è già incluso)
INCLUDE_SECRETS_DIR="${INCLUDE_SECRETS_DIR:-1}"              # password del keyring (SBX_SECRETS_DIR), cifrata gpg
SECRETS_PASSPHRASE_FILE="${SECRETS_PASSPHRASE_FILE:-}"       # passphrase gpg da file; vuoto = interattiva
INCLUDE_IMAGE="${INCLUDE_IMAGE:-0}"                          # 1 = docker save dell'immagine (PC senza registry)

COMPRESSOR="${COMPRESSOR:-zstd}"                             # zstd | gzip | none
COMPRESS_LEVEL="${COMPRESS_LEVEL:-3}"
ASSUME_YES="${ASSUME_YES:-0}"                                # 1 = non chiedere conferma prima dello stop
RESTART_AFTER="${RESTART_AFTER:-1}"                          # riavvia il container se era attivo
WRITE_MANIFEST="${WRITE_MANIFEST:-1}"                        # MANIFEST.txt per la verifica 1:1 al restore
# =============================================================================

log()  { printf '\033[1;34m[C-backup]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[C-backup] ATTENZIONE:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[C-backup] ERRORE:\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "comando mancante: $1"; }

case "$COMPRESSOR" in
  zstd) EXT=".zst"; ZCMD="zstd -q -T0 -${COMPRESS_LEVEL} -c" ;;
  gzip) EXT=".gz";  ZCMD="gzip -c -${COMPRESS_LEVEL}" ;;
  none) EXT="";     ZCMD="cat" ;;
  *)    die "COMPRESSOR non valido: $COMPRESSOR" ;;
esac

# Elenco 1:1 di un albero (eseguito nel container helper, come root): metadati di
# ogni voce, sha256 del contenuto, xattr e ACL (system.posix_acl_*) di ogni voce. I file grandi (dischi VM sparse) si hashano
# come stream tar sparse con metadati azzerati: i buchi non vengono letti.
# I socket sono esclusi (tar non li copia).
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
[[ "$COMPRESSOR" == zstd ]] && need zstd
[[ -f "$COMPOSE_FILE" ]] || die "compose non trovato: $COMPOSE_FILE"
DC=(docker compose -f "$COMPOSE_FILE"); [[ -n "$COMPOSE_PROJECT" ]] && DC+=(-p "$COMPOSE_PROJECT")
CFG=$("${DC[@]}" config --format json) || die "docker compose config fallito"
SVC=$(jq -e --arg s "$SERVICE" '.services[$s]' <<<"$CFG") || die "servizio $SERVICE non trovato"
IMAGE=$(jq -r '.image' <<<"$SVC")
CNAME=$(jq -r '.container_name // empty' <<<"$SVC")
src_of() { jq -r --arg t "$1" '.volumes[]? | select(.type == "bind" and .target == $t) | .source' <<<"$SVC"; }
DOCKER_SRC=$(src_of /var/lib/docker); [[ -n "$DOCKER_SRC" ]] || die "nessun bind su /var/lib/docker: non è docker-compose.sbx.bind.yml?"
SBX_DATA=$(dirname "$DOCKER_SRC")
SECRETS_SRC=$(src_of /run/secrets/sbx)
WS_TARGET=$(jq -r '.volumes[]? | select(.type == "bind" and (.target | startswith("/home/alpine") | not)
  and .target != "/var/lib/docker" and .target != "/run/secrets/sbx") | .target' <<<"$SVC" | head -1)
WS_SRC=""; [[ -n "$WS_TARGET" ]] && WS_SRC=$(src_of "$WS_TARGET")
OUTSIDE=$(jq -r --arg d "$SBX_DATA/" '.volumes[]? | select(.type == "bind" and ((.source + "/") | startswith($d) | not)) | "\(.source) → \(.target)"' <<<"$SVC")
[[ -d "$SBX_DATA" ]] || die "SBX_DATA $SBX_DATA non esiste"
BACKUP_NAME="${BACKUP_NAME:-sbxC-${CNAME:-sbx}-${STAMP}}"
mkdir -p "$BACKUP_DIR"; BACKUP_DIR=$(cd "$BACKUP_DIR" && pwd -P)
[[ "$BACKUP_DIR/" == "$SBX_DATA/"* ]] && die "BACKUP_DIR non può stare dentro SBX_DATA"
ARCHIVE="$BACKUP_DIR/$BACKUP_NAME.tar"; STAGING="$BACKUP_DIR/.$BACKUP_NAME.staging"
[[ -e "$ARCHIVE" || -e "$STAGING" ]] && die "esiste già $ARCHIVE"
WS_INSIDE=0; [[ -n "$WS_SRC" && "$WS_SRC/" == "$SBX_DATA/"* ]] && WS_INSIDE=1

log "container ${CNAME:-?} immagine $IMAGE"
log "SBX_DATA = $SBX_DATA ($(du -sh --apparent-size "$SBX_DATA" 2>/dev/null | cut -f1) apparenti)"
log "workspace = ${WS_SRC:-<nessuno>} → ${WS_TARGET:-}$([[ $WS_INSIDE == 1 ]] && echo ' (dentro SBX_DATA)')"
[[ -n "$OUTSIDE" ]] && log "bind fuori da SBX_DATA:"$'\n'"$(sed 's/^/      /' <<<"$OUTSIDE")"

WAS_RUNNING=0
[[ -n "$("${DC[@]}" ps -q --status running "$SERVICE" 2>/dev/null)" ]] && WAS_RUNNING=1
if [[ "$WAS_RUNNING" == 1 && "$ASSUME_YES" != 1 ]]; then
  read -r -p "Il container ${CNAME:-$SERVICE} (sandbox comprese) verrà fermato per la copia. Procedo? [si/NO] " ans < /dev/tty
  [[ "$ans" =~ ^(s|si|sì|y|yes)$ ]] || die "annullato dall'utente"
fi

STOPPED=0
restart() { [[ "$STOPPED" == 1 && "$RESTART_AFTER" == 1 ]] && { log "riavvio container"; "${DC[@]}" start "$SERVICE" >/dev/null || warn "riavvio fallito"; }; STOPPED=0; }
on_error() { local rc=$?; warn "backup fallito (exit $rc, riga ${BASH_LINENO[0]})"; rm -rf -- "$STAGING" "$ARCHIVE.partial"; restart; exit "$rc"; }
trap on_error ERR
mkdir -p "$STAGING"

if [[ "$WAS_RUNNING" == 1 ]]; then
  log "docker compose stop (sandbox → sbx → dockerd, fino a stop_grace_period)"
  "${DC[@]}" stop "$SERVICE" >/dev/null; STOPPED=1
fi

helper() {  # $@ = comando sh nel container helper (root), SBX_DATA su /src (ro), STAGING su /out
  local extra=(); [[ -n "$WS_SRC" && "$WS_INSIDE" == 0 ]] && extra=(-v "$WS_SRC:/ws:ro")
  docker run --rm --network none -u 0 --cap-add SYS_ADMIN --entrypoint bash -v "$SBX_DATA:/src:ro" -v "$STAGING:/out" "${extra[@]}" "$IMAGE" -c "$@"
}

log "copia SBX_DATA (tar sparse, owner numerici, xattr/ACL)"
# I socket (sbx-run, sandboxd) esistono solo a runtime: tar li salta, il suo avviso si filtra.
helper "tar -C /src --format=posix --pax-option=delete=atime,delete=ctime --sparse --numeric-owner --xattrs --xattrs-include='*' --acls -cpf - . 2> >(grep -v ': socket ignored\$' >&2) | $ZCMD > /out/data.tar$EXT"
if [[ "$WRITE_MANIFEST" == 1 ]]; then
  log "manifest 1:1 (metadati + sha256)"
  helper "$MANIFEST_SH" _ /src > "$STAGING/MANIFEST.txt"
fi
if [[ -n "$WS_SRC" && "$WS_INSIDE" == 0 && "$INCLUDE_WORKSPACE" == 1 ]]; then
  log "copia workspace $WS_SRC"
  helper "tar -C /ws --format=posix --pax-option=delete=atime,delete=ctime --numeric-owner -cpf - . | $ZCMD > /out/workspace.tar$EXT"
fi
helper "chown -R $(id -u):$(id -g) /out"
restart

# La cartella secret può essere di root (creata da Docker) e non leggibile: la legge l'helper.
sec() { docker run --rm -i --network none -u 0 --entrypoint bash -v "$SECRETS_SRC:/sec:ro" "$IMAGE" -c "$1"; }
if [[ "$INCLUDE_SECRETS_DIR" == 1 && -n "$SECRETS_SRC" && -d "$SECRETS_SRC" ]] && sec '[ -n "$(ls -A /sec)" ]'; then
  need gpg
  log "cartella secret $SECRETS_SRC (cifrata gpg AES256)"
  GPG=(gpg --quiet --symmetric --cipher-algo AES256 --output "$STAGING/secrets.tar.gpg")
  [[ -n "$SECRETS_PASSPHRASE_FILE" ]] && GPG+=(--batch --yes --pinentry-mode loopback --passphrase-file "$SECRETS_PASSPHRASE_FILE")
  sec 'tar -C /sec --numeric-owner -cpf - .' | "${GPG[@]}"
fi

if [[ "$INCLUDE_IMAGE" == 1 ]]; then
  log "docker save $IMAGE"
  docker save "$IMAGE" | $ZCMD > "$STAGING/image.tar$EXT"
fi

jq . <<<"$CFG" > "$STAGING/compose.json"
printf '%s=%s\n' FORMAT sbx-backup-C FORMAT_VERSION 1 CREATED_AT "$(date -Iseconds)" SOURCE_HOST "$(hostname)" \
  IMAGE "$IMAGE" IMAGE_ID "$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null)" CONTAINER "$CNAME" \
  SBX_DATA "$SBX_DATA" SECRETS_DIR "$SECRETS_SRC" WS_SOURCE "$WS_SRC" WS_TARGET "$WS_TARGET" WS_INSIDE "$WS_INSIDE" \
  SBX_VERSION "$(docker run --rm --entrypoint sbx "$IMAGE" version 2>/dev/null | awk '{print $3}')" > "$STAGING/manifest.env"
(cd "$STAGING" && sha256sum -- * > SHA256SUMS)
PARTS=(); for f in "$STAGING"/*; do [[ "${f##*/}" == manifest.env ]] || PARTS+=("${f##*/}"); done
tar -cf "$ARCHIVE.partial" -C "$STAGING" manifest.env "${PARTS[@]}"
mv -- "$ARCHIVE.partial" "$ARCHIVE"; rm -rf -- "$STAGING"
trap - ERR
log "OK → $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
tar -tf "$ARCHIVE" | sed 's/^/    /' >&2
