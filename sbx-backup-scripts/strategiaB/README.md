# Strategia B: backup e ripristino raw "a freddo" 1:1

Copia **byte per byte** (gestendo i file sparse) **tutto lo stato** di Docker Sandboxes in **un solo file** `.tar.zst`. Sul PC di destinazione lo stato viene rimesso identico: stesse sandbox, stessi ID, volumi, snapshot, template, policy e spec.

**Quando usarla:** migrazione da Linux a Linux con stesso utente e stessi percorsi, e si vuole un clone vero.
**Quando no:** destinazione Mac o Windows, utente o HOME diversi, versione sbx diversa → [strategia A](../strategiaA/README.md).

> ⚠️ Il backup **ferma tutte le sandbox e il daemon sbx** per tutta la durata della copia (circa 20–50 GB). Poi li riavvia.
> ⚠️ Usa il formato interno di sbx, **non documentato**: una nuova versione di sbx può cambiarlo. Prova sempre il restore prima di cancellare il PC sorgente.

---

## 1. Cosa viene copiato

| Percorso (relativo alla HOME) | Contenuto | Dimensione su `i7-lenovo-work` |
|---|---|---|
| `.local/state/sandboxes/` | containerd embedded: snapshot rootfs (erofs), volumi block (`*-docker.img`, `sandbox-plugin-*-claude-*.img` = `~/.claude/projects` ecc.), spec in `runtimes/*.json`, chiave SSH, audit | 48G reali (24G sono il `docker.img` mai ripulito) |
| `.cache/sandboxes/` | `policykit/governor.db` (policy di rete), feature flag | 544K |
| `.config/sandboxes/` | `sbx settings set` (es. disco DinD, kit consentiti) | KB |
| `.config/sbx/` | binding approvati da `sbx env` (`credentials.yaml`), se presente | KB |
| `.config/com.docker.sandboxes/` | file dei secret usato solo senza Secret Service, se presente | KB |
| `.local/share/sandboxes/` | dati client | KB |
| `.sbx/` | cartella runtime | ~0 |
| *(opzionale)* workspace host | es. `/mnt/fabio/dati/Git`, salvato con percorso assoluto | variabile |
| file host dei server MCP locali | script/binari nominati con percorso assoluto nel comando (`INCLUDE_MCP_HOST_FILES=1`), ripristinati solo se mancano | KB |
| *(opzionale)* `secrets.json.gpg` | credenziali sbx dal **keyring OS**: **non** stanno nelle cartelle sopra | KB |

Dentro `.local/state/sandboxes/` ci sono anche lo skill store (`sbx skills`), il registro MCP (`sbx mcp`), le porte pubblicate (`runtimes/ports/`), i kit e i template salvati: la configurazione di **tutti gli agent** (claude, codex, copilot, cursor, devin, docker-agent, droid, gemini, kiro, opencode, shell) sta nei dischi delle VM e nei volumi dei kit, quindi è inclusa.

Esclusi di default: `daemon.log*`, `client.log`, `tui.log`, `crashes/`, `mcp/*.log` (`INCLUDE_LOGS=1` per includerli).

**Le credenziali non stanno nello stato su disco.** sbx le tiene nel Secret Service (gnome-keyring): `docker/sandbox/credentials/<sandbox>/<nome>` (della sandbox), `.../credentials/_/<nome>` (globali, anche `--command` e i client secret MCP), `.../credentials/_all/registry:<host>` (registry), `docker/sandbox/default/<nome>`, più il login Docker (`com.docker.sandboxes-auth`). Una copia raw delle cartelle **non** le porta: per questo gli script le esportano a parte, cifrate con gpg.

---

## 2. Requisiti (vincolanti)

| Requisito | Perché |
|---|---|
| Linux, **stessa architettura** (x86_64) | snapshot e immagini sono legati all'architettura |
| **Stessa versione sbx** (v0.50.1) | formato interno non stabile; `CHECK_SBX_VERSION=1` blocca |
| **Stessa HOME** (`/home/fabio`) | percorsi assoluti nei DB bolt e nei JSON; `CHECK_HOME_PATH=1` blocca |
| **Stessi percorsi dei workspace** (`/mnt/fabio/dati/Git`) | la spec della sandbox punta al percorso assoluto |
| `/dev/kvm` accessibile (utente nel gruppo `kvm`) | le sandbox sono microVM |
| `tar` (GNU), `zstd`, `jq`, `pgrep`; per le credenziali `gpg` + `python3-secretstorage` | |
| Spazio: circa la dimensione reale dello stato | lo script controlla |

---

## 3. Uso rapido

```bash
# PC sorgente: ferma tutto, copia, riavvia (chiede conferma)
./backup.sh
ASSUME_YES=1 BACKUP_DIR=/media/usb INCLUDE_WORKSPACES=1 ./backup.sh

# PC destinazione: stessa versione sbx installata, utente fabio
./restore.sh /media/usb/sbxB-full-i7-lenovo-work-20261029-120000.tar.zst
EXISTING_STATE=move START_SANDBOXES_AFTER=1 ./restore.sh backup.tar.zst
```

Tutte le variabili sono in testa agli script e si possono sovrascrivere da ambiente.

---

## 4. `backup.sh`: cosa fa, passo per passo

1. **Preflight:** controlla comandi e cartelle (devono stare sotto `SOURCE_HOME`), stima lo spazio (`du` reale contro `df`).
2. **Metadati**, a daemon ancora attivo: `sbx ls --json`, lista template, nomi dei secret, policy globale e per sandbox, settings non di default, `uname`/`os-release`/`id`. Annota le sandbox **running**, per riavviarle dopo.
3. **Credenziali** (`INCLUDE_SECRETS=1`): export dal keyring, cifrato con gpg AES256 (il JSON in chiaro passa solo in pipe). `SECRETS_ID_FILTER` limita gli item con una regex sull'ID.
4. Crea `meta.tar` (manifest, metadata e secrets), **primo membro** dell'archivio: il restore lo legge senza decomprimere tutto.
5. **Conferma** (salvo `ASSUME_YES=1`).
6. **`fstrim /var/lib/docker`** in ogni sandbox running (`TRIM_DIND_BEFORE_STOP=1`): libera i blocchi cancellati negli `.img` sparse. In un test: 961M → 6.7M. Su `claude-developmanet` dovrebbe portare il `docker.img` da 24G a circa 250M.
7. **Stop:** `sbx stop <running…>` → `sbx daemon stop` → attesa che il processo `sbx daemon start` sparisca (`STOP_TIMEOUT`).
8. **Copia:** `tar --sparse -cpf - meta.tar <stato> [workspace] | zstd -T0` → `.partial`. Un exit code di tar ≠ 0 è considerato un errore, perché con il daemon fermo nulla deve cambiare.
9. Rinomina `.partial` → `.tar.zst` e scrive `<file>.sha256` (`WRITE_SHA256_SIDECAR=1`).
10. **Riavvio sempre**, anche in caso di errore (trap EXIT): `sbx daemon start --detach` e `sbx run -d --name <s>` per le sandbox che erano running.

Procedura manuale equivalente:
```bash
sbx exec claude-developmanet sudo fstrim -v /var/lib/docker      # opzionale, riduce l'img
sbx stop claude-developmanet && sbx daemon stop
tar --sparse -cpf - -C ~ .local/state/sandboxes .cache/sandboxes .sbx | zstd -T0 > sbx-full.tar.zst
sbx daemon start --detach && sbx run -d --name claude-developmanet
```

### Configurazione `backup.sh`

| Variabile | Default | Significato |
|---|---|---|
| `SOURCE_HOME` | `$HOME` | HOME che contiene lo stato |
| `SBX_STATE_DIR` / `SBX_CACHE_DIR` / `SBX_RUN_DIR` | `~/.local/state/sandboxes` / `~/.cache/sandboxes` / `~/.sbx` | cartelle copiate |
| `BACKUP_DIR` / `BACKUP_NAME` | `~/sbx-backups` / `sbxB-full-<host>-<data>` | destinazione |
| `COMPRESSOR` / `COMPRESS_LEVEL` | `zstd` / `3` | `zstd`, `gzip` o `none` |
| `INCLUDE_LOGS` | `0` | log e crash del daemon |
| `INCLUDE_WORKSPACES` | `0` | workspace di tutte le sandbox, con percorso assoluto |
| `INCLUDE_MCP_HOST_FILES` | `1` | file host dei server MCP locali (percorsi assoluti del comando fuori da `/usr`, `/bin`, `/lib`, `/etc`…) |
| `WORKSPACES_OVERRIDE` | vuoto | lista esplicita (vuoto = da `sbx ls`) |
| `WORKSPACE_EXCLUDES` | vuoto | pattern `--exclude`, es. `"node_modules .venv"` |
| `INCLUDE_SECRETS` | `1` | credenziali sbx dal keyring, cifrate |
| `INCLUDE_DOCKER_LOGIN` | `0` | anche il login Docker Hub |
| `SECRETS_PASSPHRASE_FILE` | vuoto | passphrase gpg; vuoto = interattiva |
| `SECRETS_ID_FILTER` | vuoto | regex sugli ID dei secret (vuoto = tutti) |
| `TRIM_DIND_BEFORE_STOP` | `1` | `fstrim` nelle sandbox prima dello stop |
| `ASSUME_YES` | `0` | nessuna conferma |
| `STOP_TIMEOUT` | `120` | secondi |
| `RESTART_DAEMON_AFTER` / `RESTART_SANDBOXES_AFTER` | `1` / `1` | riavvio a fine backup |
| `WRITE_SHA256_SIDECAR` | `1` | file `.sha256` accanto all'archivio |
| `UNSAFE_SKIP_STOP` | `0` | **solo test**: non ferma nulla, la copia è inconsistente |
| `SBX_BIN` | `sbx` | |

---

## 5. `restore.sh`: cosa fa, passo per passo

1. Verifica il `.sha256` (se c'è), riconosce la compressione (zstd, gzip o nessuna) e legge `meta.tar`.
2. **Controlli bloccanti:** versione sbx, architettura, HOME uguale all'originale, `/dev/kvm`, spazio. Avvisa se l'utente è diverso.
3. Se la destinazione è la HOME reale e il daemon è attivo: **conferma**, `sbx stop` delle sandbox locali, `sbx daemon stop`. Con `STOP_DAEMON=0` invece **si rifiuta di procedere**.
4. **Stato esistente:** `EXISTING_STATE=abort` (default) si ferma; `move` rinomina le cartelle in `*.pre-restore-<data>` (se la cartella è un mount point, come nel container `docker-compose.sbx.bind.yml`, ne sposta il contenuto). Non cancella mai nulla.
5. Estrae lo stato in `TARGET_HOME` (i file sparse tornano sparse), poi i workspace in `WORKSPACE_ROOT`, saltando quelli non vuoti salvo `WORKSPACE_OVERWRITE=1`.
6. **Credenziali:** gpg → keyring, con gli stessi ID.
7. `sbx daemon start --detach`, `sbx ls`, e con `START_SANDBOXES_AFTER=1` riavvia le sandbox che erano running.
8. Passi finali: `sbx login` se richiesto, `sbx secret ls`, `sbx run --name <sandbox>`.

Procedura manuale equivalente (PC nuovo, stessa versione sbx, utente `fabio`):
```bash
sbx daemon stop 2>/dev/null || true
zstd -dc sbx-full.tar.zst | tar -C ~ -xpf -
sbx daemon start --detach && sbx ls
sbx secret set github --sandbox claude-developmanet    # se non hai esportato le credenziali
sbx run --name claude-developmanet
```

### Configurazione `restore.sh`

| Variabile | Default | Significato |
|---|---|---|
| `$1` / `BACKUP_FILE` | — | archivio |
| `TARGET_HOME` | `$HOME` | dove estrarre (deve essere la HOME originale) |
| `EXISTING_STATE` | `abort` | `abort` o `move` |
| `STOP_DAEMON` | `1` | ferma il daemon locale se attivo |
| `START_DAEMON_AFTER` / `START_SANDBOXES_AFTER` | `1` / `0` | avvio finale |
| `RESTORE_WORKSPACES` | `auto` | `auto`, `1` o `0` |
| `WORKSPACE_ROOT` | `/` | radice di estrazione dei workspace (≠ `/` rompe i percorsi della spec) |
| `WORKSPACE_OVERWRITE` | `0` | |
| `RESTORE_MCP_HOST_FILES` | `1` | file host dei server MCP, solo dove mancano |
| `RESTORE_SECRETS` | `auto` | `auto`, `1` o `0` |
| `SECRETS_PASSPHRASE_FILE` | vuoto | passphrase gpg |
| `CHECK_SBX_VERSION` / `CHECK_HOME_PATH` / `CHECK_ARCH` / `CHECK_KVM` | `1` | controlli bloccanti |
| `ASSUME_YES` | `0` | |
| `STOP_TIMEOUT` | `120` | |
| `SBX_BIN` | `sbx` | |

---

## 6. Note e limiti

- **Fermo macchina:** tutte le sandbox restano ferme per la durata di `tar` + `zstd`. Con `fstrim` lo stato di `i7-lenovo-work` scende da circa 48G a circa 25G reali.
- **Workspace:** se non lo includi, copialo a parte (rsync o git) **nello stesso percorso assoluto**, prima di avviare la sandbox.
- **Login Docker di sbx:** OAuth con refresh token che ruota a ogni rinnovo (ogni 15 minuti): una copia vale finché uno dei due lati non rinnova, poi l'altro viene sloggato (`secret not found`). Non viene copiato di default: dopo il restore esegui `sbx login`, e non tenere accesi insieme sorgente e copia.
- **opencode:** il kit riscrive `~/.config/opencode/opencode.json` a ogni avvio della sandbox; le chiavi aggiunte a mano si perdono anche senza backup.
- **OAuth Anthropic copiato:** stessa avvertenza della strategia A (rotazione del refresh token). Usa la sandbox su un solo PC.
- **Rete:** nomi di rete e proxy sono nello stato; sbx li ricrea all'avvio. Se qualcosa non riparte, `sbx diagnose`.
- **Sicurezza:** l'archivio contiene la chiave SSH di sbx (`docker_sandboxes_ssh_ed25519`) e, se incluso, `secrets.json.gpg`. Proteggilo come un backup sensibile.
- **Rollback:** il PC sorgente resta intatto. Sul destinatario, con `EXISTING_STATE=move`, lo stato precedente resta in `*.pre-restore-<data>`.

## 7. Test eseguiti (29/10/2026, sbx v0.50.1)

`claude-developmanet` mai toccata: il daemon sbx dell'host non è stato fermato. Lo stop e il riavvio del daemon sono stati provati dentro i container di `docker-compose.sbx.bind.yml`, dove lo script gira identico (HOME `/home/alpine`).

**Matrice completa** (dettagli in [README_SBX.md](../../README_SBX.md#test)): 11 sandbox, una per agent, personalizzate in un container (le stesse della strategia A), salvate con `backup.sh` e ripristinate in un altro container che aveva già uno stato sbx e un suo login (`EXISTING_STATE=move`).
- Backup: 268 s a daemon fermo, archivio da 13G (stato di 11 sandbox, workspace, file host MCP, secret cifrati).
- Restore: 534 s; 11 sandbox e 6 secret ripristinati; il login della destinazione resta valido (il login non viene copiato).
- Verifica: 90 controlli funzionali e impronta completa di ogni sandbox (hash, permessi, owner, mtime di ogni file; spec, porte, MCP, skill, secret, policy, settings, Docker interno) identici all'origine. Unica differenza: il login Docker.

**Test precedenti su una HOME finta:** `.img` sparse da 2G con 5M di dati → archivio da 5,1M → ripristinate identiche (`cmp`) e ancora sparse; log e socket esclusi, permessi preservati; workspace ripristinato sotto `WORKSPACE_ROOT`; protezioni: rifiuto di HOME diversa, della HOME reale con daemon attivo e `STOP_DAEMON=0`, di uno stato già presente; modalità `move`.

**Prima migrazione reale consigliata:** sul PC nuovo lancia `restore.sh`, verifica con `sbx ls` e `sbx run`, e solo dopo dismetti il PC vecchio.
