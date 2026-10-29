# Strategia A: backup e ripristino per "ricostruzione"

Salva **una** sandbox sbx in **un solo file `.tar`**, usando solo comandi supportati da sbx (`template save/load`, `exec`, `create`). Sul PC di destinazione ricrea una sandbox equivalente nel contenuto, con un nuovo ID.

**Quando usarla:** il PC di destinazione ha un sistema operativo, un utente o una versione di sbx diversi, oppure si vuole migrare una sola sandbox senza fermare il daemon.
**Quando non basta:** serve un clone bit per bit di *tutte* le sandbox, con lo stesso ID → [strategia B](../strategiaB/README.md).

---

## 1. Perché `sbx template save/load` da solo perde pezzi

`template save` cattura solo il **rootfs** della sandbox. Tutto il resto vive fuori:

| Pezzo | Dove sta | Template | Questo backup |
|---|---|---|---|
| rootfs: pacchetti, `/etc`, `/usr/local`, config degli agent senza volume (`~/.codex`, `~/.gemini`, `~/.factory`, `~/.config/opencode`, `~/.kiro`, `~/.copilot`, `~/.cursor`, `~/.config/devin`, `~/.claude.json`, plugin e skill di Claude) | snapshot del rootfs | ✅ | ✅ `rootfs.tar.zst` |
| Config che il kit riscrive a ogni `sbx create`: claude `~/.claude.json` e `~/.claude/settings.json` (plugin abilitati, marketplace, MCP utente), codex `~/.codex/config.toml`, gemini `~/.gemini/settings.json`, kiro `data.sqlite3`, copilot, cursor, droid | rootfs, ma la create le sovrascrive | ❌ | ✅ `agent-config.tar.zst`, rimesse dopo la create |
| Volumi persistenti del kit (claude: `~/.claude/{projects,sessions,todos,shell-snapshots,statsig}`; rilevati da `/proc/mounts`, anche per agent futuri) | volumi block `*.img` | ❌ | ✅ `volumes.tar.zst` |
| Docker interno (`/var/lib/docker`: immagini, container, reti, volumi, cache) | volume block `<nome>-docker.img` | ❌ | ✅ `dind.tar.zst` (`DIND_MODE=raw`) o immagini + volumi (`export`) |
| Spec: agent, CPU, RAM, workspace (anche `:ro`), env `-e`, skill, MCP statici, kit, profilo, disco DinD | `runtimes/<nome>.json` | ❌ | ✅ `spec.json` + `manifest.env` |
| Porte pubblicate, con protocollo (`tcp4`, `tcp6`, `udp`…) | `runtimes/ports/<sha256(nome)>.json` | ❌ | ✅ ripubblicate |
| Regole di rete aggiunte (sandbox e globali), `--deny-network` | `governor.db` | ❌ | ✅ riapplicate |
| Config globale: `sbx settings set`, registro MCP (`sbx mcp`), skill store (`sbx skills`) | stato sbx | ❌ | ✅ `global.tar` (non sovrascrive) |
| MCP della sandbox: statici (`--static-mcp`, nella spec) e caricati dopo (`sbx mcp load`, in `mcp/gateways/<nome>.json`) | stato sbx | ❌ | ✅ ricreati / ricaricati |
| File host dei server MCP locali (script e binari nominati con percorso assoluto nel comando, es. `sbx mcp add --command python3 --args /home/me/mcp.py`) | disco host | ❌ | ✅ `global.tar` (ripristinati solo se mancano) |
| Secret: della sandbox, globali, `--command`, registry (`_all`), client secret MCP | keyring | ❌ | ✅ `secrets.json.gpg` (cifrato) |
| Variabili `sbx create -e` | spec | ❌ | ✅ cifrate con i secret |
| Workspace host | disco host | ❌ | ⚙️ `INCLUDE_WORKSPACE=1` |
| Login Docker di sbx | keyring | ❌ | ❌ si rifà `sbx login` (v. note) |

## 2. Requisiti

**PC sorgente:** `sbx`, `tar`, `jq`, `sha256sum`, `zstd` (oppure `COMPRESSOR=gzip`). Per le credenziali servono anche `gpg` e `python3-secretstorage`.
**PC destinazione:** `sbx` (meglio la stessa versione, v0.50.1), `sbx login` fatto **su quel PC**, `git` per copilot/droid/kiro, `tar`, `jq`, `zstd`. Per le credenziali: `gpg` e `python3-secretstorage` (`sudo apt install python3-secretstorage`).

**Spazio disco:**
- backup: circa 2 volte il rootfs usato (file temporaneo + archivio);
- restore: circa archivio + rootfs decompresso.

---

## 3. Uso rapido

```bash
# PC sorgente
./backup.sh claude-dev                        # chiede conferma prima dello stop per lo snapshot
ASSUME_YES=1 BACKUP_DIR=/media/usb ./backup.sh claude-dev

# copia il file sbxA-<nome>-<data>.tar sul PC nuovo, poi:
./restore.sh /media/usb/sbxA-claude-dev-20261029-120000.tar
```

Tutte le variabili di configurazione sono in testa agli script e si possono sovrascrivere da ambiente, ad esempio `VAR=valore ./script.sh`.

---

## 4. `backup.sh`: cosa fa, passo per passo

1. **Preflight:** comandi, sandbox esistente (`sbx ls --json`), spazio libero; legge spec, porte (dal file del runtime: `sbx ports` le mostra solo a sandbox accesa) e policy.
2. **Conferma** (salta con `ASSUME_YES=1`): rootfs e Docker interno raw richiedono di fermare **solo quella sandbox**, non il daemon. Se è ferma, `sbx exec` la avvia temporaneamente.
3. **`manifest.env`, `spec.json`, `metadata/`:** versione sbx, spec completa, porte, regole policy, MCP, skill, settings non di default, nomi dei secret (mai i valori), stato interno (`df`, Docker).
4. **Volumi persistenti** del kit, rilevati da `/proc/mounts` (tutti i block device tranne `/var/lib/docker`): `tar` in streaming dalla sandbox all'host. Poi le **config degli agent** (`AGENT_CONFIG_FILES`) che esistono nella sandbox → `agent-config.tar`.
5. **Docker interno:** `raw` ferma dockerd nella sandbox e copia tutto `/var/lib/docker`; `export` fa `docker save` + volumi `local`.
6. **Rootfs:** `sbx stop` → `sbx template save -o rootfs.tar` → compressione → rimozione del template locale.
7. **Config globale** (`global.tar`, con i file host dei server MCP locali: percorsi assoluti del comando fuori da `/usr`, `/bin`, `/lib`, `/etc`…), **workspace** (opzionale, con esclusioni; `BACKUP_DIR` dentro il workspace viene escluso).
8. **Credenziali e env:** item del keyring della sandbox e globali (`credentials/<nome>/*`, `credentials/_/*`, `credentials/_all/*`, `default/*`), più le variabili `-e`, cifrati con **gpg AES256**. Il JSON in chiaro passa solo in pipe.
9. Ogni pezzo entra nel `.tar` con il suo SHA256; alla fine `SHA256SUMS` e rinomina `.partial` → `.tar`. La sandbox torna nello stato iniziale (riavvio detached se era accesa).

In caso di errore rimuove i parziali e il template temporaneo e **riavvia comunque la sandbox** se l'aveva fermata.

### Configurazione `backup.sh`

| Variabile | Default | Significato |
|---|---|---|
| `SANDBOX_NAME` | primo argomento | sandbox da salvare (obbligatoria) |
| `BACKUP_DIR` / `BACKUP_NAME` / `STAMP` | `~/sbx-backups` / `sbxA-<nome>-<data>` / data | destinazione e nome del file |
| `TEMPLATE_TAG` / `KEEP_LOCAL_TEMPLATE` | `sbx-backup/<nome>:<data>` / `0` | tag del rootfs; `1` = lascia il template |
| `PERSISTENT_PATHS` | `auto` | volumi del kit; oppure lista di path |
| `INCLUDE_ROOTFS` / `INCLUDE_PERSISTENT_VOLUMES` | `1` / `1` | singoli pezzi |
| `AGENT_CONFIG_FILES` | config di claude, codex, gemini, kiro, copilot, cursor, droid | file riscritti dal kit alla create; vuoto = nessuno |
| `DIND_MODE` | `raw` | `raw` (tutto `/var/lib/docker`), `export` (immagini + volumi), `none` |
| `INCLUDE_DIND_IMAGES` / `INCLUDE_DIND_VOLUMES` | `1` / `1` | solo con `export` |
| `INCLUDE_GLOBAL_CONFIG` | `1` | settings, registro MCP, skill store |
| `INCLUDE_MCP_HOST_FILES` | `1` | file host dei server MCP locali |
| `INCLUDE_WORKSPACE` / `WORKSPACE_EXCLUDES` | `0` / vuoto | workspace host, es. `"node_modules .venv target"` |
| `INCLUDE_SECRETS` / `INCLUDE_GLOBAL_SECRETS` | `1` / `1` | secret della sandbox / globali |
| `INCLUDE_DOCKER_LOGIN` | `0` | login Docker di sbx (sconsigliato, v. note) |
| `INCLUDE_ENV` | `1` | variabili `-e` |
| `SECRETS_PASSPHRASE_FILE` | vuoto | passphrase gpg da file; vuoto = interattiva |
| `ASSUME_YES` / `RESTART_AFTER` | `0` / `1` | conferma / riavvio se era accesa |
| `DOCKERD_STOP_TIMEOUT` | `60` | attesa dello stop di dockerd (`raw`) |
| `COMPRESSOR` / `COMPRESS_LEVEL` | `zstd` / `3` | `zstd`, `gzip`, `none` |
| `SBX_BIN` / `SBX_STATE_DIR` | `sbx` / `~/.local/state/sandboxes/sandboxes` | |
| `KEEP_STAGING_ON_ERROR` | `0` | debug |

---

## 5. `restore.sh`: cosa fa, passo per passo

1. Legge `manifest.env` (formati 1, 2, 3), **verifica lo SHA256** di ogni pezzo, avvisa se la versione sbx è diversa.
2. Si **ferma se esiste già** una sandbox con quel nome: non cancella né sovrascrive nulla.
3. **Workspace:** estratti solo in cartelle vuote (o `WORKSPACE_OVERWRITE=1`); se mancano li crea vuoti.
4. **Policy globale:** se sul PC nuovo non è inizializzata, la inizializza come l'origine (`POLICY_INIT=auto`).
5. **Config globale:** settings ancora di default, server MCP e skill mancanti (quelli già presenti restano), file host dei server MCP che qui mancano.
6. **Credenziali ed env:** gpg → keyring, *prima* della create; se il nome cambia, lo scope `credentials/<vecchio>/` viene rinominato. Le variabili `-e` vanno in un `--env-file` temporaneo (0600).
7. `sbx template load` → `sbx create` con le stesse opzioni (agent, CPU, RAM, workspace e `:ro`, skill, MCP statici, profilo, `DOCKER_SANDBOXES_DOCKER_SIZE` per il disco DinD). Se la create fallisce per un MCP statico che qui non parte, la ripete senza e lo carica dopo, con un avviso.
8. **Volumi persistenti** in streaming, poi le **config degli agent** sopra quelle appena scritte dal kit; per claude rinomina `~/.claude/projects/<vecchio-path>` se il workspace cambia.
9. **Docker interno:** `raw` sostituisce `/var/lib/docker` a dockerd fermo; `export` fa `docker load` + volumi.
10. **MCP** caricati con `sbx mcp load` sull'origine, **regole di rete** (sandbox e globali mancanti), **porte**.
11. Riporta la sandbox nello stato dell'origine (`FINAL_STATE=auto`) e stampa gli avvisi rimasti.

### Configurazione `restore.sh`

| Variabile | Default | Significato |
|---|---|---|
| `$1` / `BACKUP_FILE` | — | archivio `.tar` |
| `SANDBOX_NAME`, `AGENT`, `CPUS`, `MEMORY` | dal backup | `MEMORY` al massimo il 75% della RAM host |
| `WORKSPACE` | stesso percorso | workspace principale |
| `DIND_SIZE` | dal backup | disco del Docker interno, es. `30g` |
| `EXTRA_CREATE_ARGS` | vuoto | argomenti extra per `sbx create` |
| `RESTORE_WORKSPACE` / `WORKSPACE_OVERWRITE` | `auto` / `0` | |
| `RESTORE_PERSISTENT_VOLUMES` / `REMAP_CLAUDE_PROJECTS` | `1` / `1` | |
| `RESTORE_AGENT_CONFIG` | `1` | `0` = tieni le config di default del kit |
| `RESTORE_DIND` (`RESTORE_DIND_IMAGES` / `_VOLUMES` per `export`) | `1` | |
| `RESTORE_GLOBAL_CONFIG` / `RESTORE_SETTINGS` | `1` / `missing` | `missing`, `all`, `none` |
| `RESTORE_POLICY` / `RESTORE_GLOBAL_POLICY` / `POLICY_INIT` | `1` / `1` / `auto` | |
| `RESTORE_PORTS` / `RESTORE_MCP` | `1` / `1` | |
| `RESTORE_SECRETS` / `RESTORE_ENV` | `auto` / `1` | |
| `SECRETS_PASSPHRASE_FILE` | vuoto | passphrase gpg |
| `FINAL_STATE` | `auto` | `auto`, `running`, `stopped` |
| `VERIFY_CHECKSUMS` | `1` | |
| `WORK_DIR` / `KEEP_WORK_DIR` | accanto al backup / `0` | |
| `READY_TIMEOUT` | `180` | attesa sandbox e Docker pronti |

---

## 6. Procedura manuale equivalente (senza script)

```bash
S=claude-dev; W=/mnt/data/Git; B=~/sbx-backups/manual; mkdir -p $B
# --- PC sorgente
sbx exec $S tar -C /home/agent/.claude --exclude=lost+found -cpf - projects sessions todos shell-snapshots statsig | zstd > $B/claude-dirs.tar.zst
sbx exec $S sh -c 'docker save $(docker image ls --format "{{.Repository}}:{{.Tag}}" | grep -v "<none>")' | zstd > $B/dind-images.tar.zst
sbx policy ls $S > $B/policy.txt; sbx secret ls > $B/secrets.txt; sbx ls --json > $B/ls.json
sbx stop $S
sbx template save $S sbx-backup/$S:manual -o $B/rootfs.tar
sbx run -d --name $S                      # riavvio
tar -cf ~/sbx-backups/$S-manual.tar -C ~/sbx-backups manual
# --- PC destinazione (estratto in ./manual)
sbx template load manual/rootfs.tar
sbx create --name $S --pull never -t sbx-backup/$S:manual --cpus 8 -m 24g claude $W
zstd -dc manual/claude-dirs.tar.zst | sbx exec -i $S tar -C /home/agent/.claude -xpf -
zstd -dc manual/dind-images.tar.zst | sbx exec -i $S docker load
sbx secret set github --sandbox $S        # reinserisci il token
sbx run --name $S
```

---

## 7. Note e limiti

- **Stop breve obbligatorio:** `template save` rifiuta le sandbox accese. Si ferma solo la sandbox salvata; il riavvio è automatico.
- **Stesso percorso del workspace = history di Claude intatta.** Se cambia, le cartelle dei progetti vengono rinominate, ma le impostazioni per progetto in `~/.claude.json` (trust, allowedTools) restano sul vecchio percorso.
- **Login Docker di sbx:** OAuth con refresh token che ruota a ogni rinnovo (ogni 15 minuti). Una copia smette di valere appena uno dei due lati rinnova, e quello rimasto indietro viene sloggato (`secret not found`). Sul PC nuovo esegui `sbx login`; non copiarlo (`INCLUDE_DOCKER_LOGIN=0`).
- **OAuth degli agent** (es. il login Anthropic dentro la sandbox): stesso rischio di rotazione. Dopo la migrazione usa la sandbox su un solo PC, o rifai il login.
- **opencode:** il kit riscrive `~/.config/opencode/opencode.json` a ogni avvio; le chiavi aggiunte a mano lì si perdono anche senza backup.
- **Differenze attese dopo il restore:** il CA del proxy (`/etc/ssl/certs/ca-certificates.crt`, `proxy-ca.crt`, `java/cacerts`) è dell'installazione sbx di destinazione; `sbx ls` mostra `(detached)` in base a come la sandbox è stata avviata l'ultima volta; Claude può aggiungere un file in `~/.claude/backups/` al primo avvio.
- **Regole filesystem della policy:** non ricreabili da CLI, vengono solo segnalate. Le regole imposte dall'organizzazione arrivano dal login.
- **Processi:** la sandbox ripristinata riparte da zero (niente memoria dei processi). Con `DIND_MODE=raw` i container interni ci sono e ripartono secondo la loro restart policy.
- **Sicurezza:** `secrets.json.gpg` contiene token veri. Passphrase robusta, mai accanto al backup.

## 8. Test eseguiti (29/10/2026, sbx v0.50.1)

Tutti i test su sandbox e container temporanei (`-tmp`), cancellati a fine test; nessuna sandbox in uso toccata.

**Matrice completa** dentro i container di `docker-compose.sbx.bind.yml` (dettagli in [README_SBX.md](../../README_SBX.md#test)): 11 sandbox, una per agent (claude, codex, copilot, cursor, devin, docker-agent, droid, gemini, kiro, opencode, shell), personalizzate in un container e ripristinate una per una in un altro, con il suo login e senza sandbox.
- Personalizzazioni: marker nel rootfs, pacchetto apt, utente, `/opt`; config degli agent; volumi del kit; variabili `-e`; Docker interno (immagine, volume, container fermo e acceso); workspace multipli e `:ro`; porte tcp4 e udp; secret della sandbox, globali, registry e client secret MCP; MCP statico e caricato dopo; skill `readwrite` e dallo store; regole di rete della sandbox e globali; settings. Per claude anche plugin e marketplace, MCP utente, `CLAUDE.md`, agent, comandi, skill, sessioni e todo; per codex MCP, `AGENTS.md` e skill; per kiro gli steering; per opencode `AGENTS.md` e skill.
- Backup: 12–72 s per sandbox (opencode il più lento), archivi da 0,7–1,1G.
- Restore: 12–40 s per sandbox, tutti riusciti; il file host del server MCP, assente sulla destinazione, viene ripristinato.
- Verifica: 90 controlli funzionali identici all'origine, più l'impronta completa di ogni sandbox (hash, permessi e owner di ogni file; spec, porte, MCP, skill, secret, policy, settings, Docker interno). Differenze rimaste, tutte attese: login Docker (non copiato); mtime arrotondati al secondo da `template save`, e con la data del restore (stesso contenuto) per i file che il kit riscrive alla create o all'avvio (`/etc/hosts`, helper in `/usr/local/bin`, config degli agent, cartelle delle skill, `lost+found` dei volumi nuovi); un file in `~/.claude/backups/` scritto da Claude al primo avvio, il flag `(detached)` di `sbx ls`, il CA del proxy.

**Bug trovati dalla matrice e corretti:** secret registry (`credentials/_all/...`) non salvati; `create` fallita (500) per un MCP statico il cui script host mancava; MCP caricati con `sbx mcp load` dopo la create persi; config riscritte dal kit alla create perse (plugin, marketplace e MCP utente di claude, codex, gemini, kiro); porte `tcp4` ripubblicate come `tcp`; skill store ricreato 755 invece di 700.

**Test precedenti** (sbx sull'host, `sbxa-src-tmp` → `sbxa-dst-tmp`): backup su sandbox ferma e `running (detached)`, zstd e gzip; restore con nome e workspace diversi (remap della cartella progetto di Claude, secret rinominato con valore identico byte per byte); streaming binario di `sbx exec` verificato con sha256 su 20MB casuali.
