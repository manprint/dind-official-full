# Variante sbx (Docker Sandboxes dentro dind)

Variante dell'immagine con **Docker Sandboxes** (`sbx`) accanto a Docker-in-Docker: `Dockerfile.sbx`, `entrypoint.sbx.sh`, `sbx-keyring-daemon.sh`, `docker-compose.sbx.bind.yml` e gli script di backup in `sbx-backup-scripts/` (nell'immagine in `/opt/sbx-backup-scripts`). La pipeline la pubblica come `ghcr.io/manprint/dind-official-full-sbx` (amd64 e arm64), e allega alla release il compose e lo script `docker-compose.sbx.bind.yml.sh` che ne prepara le cartelle. Il pacchetto `docker-sbx` è proprietario di Docker: il suo uso è soggetto al [Docker Subscription Service Agreement](https://www.docker.com/legal/docker-subscription-service-agreement).

- Base **Ubuntu 24.04** invece di Alpine: il pacchetto `docker-sbx` contiene binari glibc ed è pubblicato solo per Ubuntu. dockerd parte con gli stessi script upstream delle altre varianti (`dind`, `dockerd-entrypoint.sh`, presi da `docker:29.9.1-dind`) dietro `entrypoint.minimal.sh`, invariato.
- `sbx` **v0.50.1** (versione Debian fissata da `ARG SBX_VERSION`): stato e template non sono garantiti tra versioni diverse.
- Tutti gli agent: `claude`, `codex`, `copilot`, `cursor`, `devin`, `docker-agent`, `droid`, `gemini`, `kiro`, `opencode`, `shell`.
- Ogni dato persistente (Docker del container, home, stato sbx, keyring, workspace) è un **bind mount sotto una sola cartella** `SBX_DATA`: la copia a freddo di quella cartella è l'intero ambiente (strategia C).
- Stessa base utente delle altre varianti: `alpine` (uid 1000) con sudo, rclone, fuse, dotfile e prompt, `DIND_ENVIRONMENT_NAME`, `DIND_DNS`, `DOCKER_DAEMON_INTERNAL_BIP`.

## Requisiti

- Host **Linux x86_64/arm64 con KVM** (`/dev/kvm`): ogni sandbox è una microVM. Docker Desktop, WSL2 e host senza virtualizzazione annidata non vanno bene.
- `privileged: true` (serve a dockerd e passa `/dev/kvm`).
- Un account Docker per `sbx login`, **uno per istanza** (v. [Login](#login-docker-di-sbx)).
- RAM: ogni sandbox avviata occupa la memoria della sua VM (`-m`, default di sbx). Tenere ferme quelle che non servono.

## Avvio

```bash
# dalla release (oppure dal repo; per un'immagine locale: just build-sbx)
for f in docker-compose.sbx.bind.yml docker-compose.sbx.bind.yml.sh; do
  curl -fsSLO https://github.com/manprint/dind-official-full/releases/latest/download/$f
done
chmod +x docker-compose.sbx.bind.yml.sh

# cartelle dei bind mount e password del keyring (fuori da SBX_DATA, v. Keyring)
./docker-compose.sbx.bind.yml.sh

docker compose -f docker-compose.sbx.bind.yml up -d
docker exec -it dind-env-sbx sbx login        # device code nel browser, una volta per istanza

docker exec -it dind-env-sbx bash
sbx create claude /workspace/progetto         # oppure: sbx run claude /workspace/progetto
sbx ls
```

Il container è `healthy` quando rispondono dockerd e il daemon sbx (non serve il login: prima di `sbx login` ogni comando sbx risponde `not signed in to Docker`).

## Volumi

Tutti sotto `SBX_DATA` (default `./data/sbx`), uno per componente. Docker crea i percorsi mancanti come root; l'entrypoint li passa ad `alpine` a ogni avvio.

| Sotto `SBX_DATA` | Nel container | Contenuto |
|---|---|---|
| `docker/` | `/var/lib/docker` | Docker del container: immagini, container, volumi |
| `home/` | `/home/alpine` | dotfile, `~/.ssh`, backup A/B |
| `sbx-state/` | `~/.local/state/sandboxes` | **tutte le sandbox**: dischi delle VM (rootfs con la config degli agent, plugin, skill, MCP), volumi persistenti dei kit (`~/.claude/projects`, sessioni, todo…), Docker interno di ogni sandbox, spec, porte pubblicate, template, kit, registro MCP, skill store, audit |
| `sbx-cache/` | `~/.cache/sandboxes` | policy di rete/filesystem (`governor.db`), feature flag |
| `sbx-config/` | `~/.config/sandboxes` | `sbx settings set` |
| `sbx-share/` | `~/.local/share/sandboxes` | dati client |
| `sbx-bindings/` | `~/.config/sbx` | binding approvati da `sbx env` (`credentials.yaml`) |
| `sbx-secrets/` | `~/.config/com.docker.sandboxes` | file di riserva dei secret (usato solo senza Secret Service) |
| `sbx-run/` | `~/.sbx` | runtime, lista delle sandbox per `SBX_AUTOSTART=previous` |
| `keyrings/` | `~/.local/share/keyrings` | keyring gnome: login Docker di sbx, `sbx secret`, client secret MCP |
| `workspace/` | `SBX_WORKSPACE_PATH` (`/workspace`) | progetti montati nelle sandbox (`SBX_WORKSPACE` per un'altra cartella host) |
| `SBX_SECRETS_DIR` (fuori) | `/run/secrets/sbx` (ro) | `keyring_pass`, la password del keyring |

La configurazione degli agent (`~/.codex`, `~/.gemini`, `~/.factory`, `~/.config/opencode`, `~/.kiro`, …) vive **dentro il disco della VM** della sandbox, quindi in `sbx-state/`: non serve un mount per agent.

**Workspace**: sbx registra nella sandbox il percorso del workspace e Claude Code ci lega la history. Conviene `SBX_WORKSPACE_PATH` uguale al percorso host (es. entrambi `/mnt/data/Git`), così backup, restore e un eventuale passaggio a sbx installato sull'host vedono lo stesso percorso.

## Variabili

Quelle del compose minimal (`DIND_TAG`, `DIND_NAME`, `DIND_TLS_PORT` (default 2378), `DIND_DNS`, `DOCKER_DAEMON_INTERNAL_BIP`, `DIND_ENVIRONMENT_NAME`, `DIND_NET_SUBNET` / `DIND_IPV4` / `DIND_NET_GATEWAY`, default `10.10.163.0/24`), più:

| Variabile | Default | Effetto |
|---|---|---|
| `SBX_DATA` | `./data/sbx` | radice di tutti i bind mount |
| `SBX_SECRETS_DIR` | `./data/sbx-secrets` | cartella con `keyring_pass`, montata in sola lettura |
| `SBX_WORKSPACE` / `SBX_WORKSPACE_PATH` | `SBX_DATA/workspace` / `/workspace` | cartella host dei progetti / dove la vedono container e sandbox |
| `SBX_AUTOSTART` | vuoto | sandbox da avviare con il container: `previous` (quelle attive all'ultimo stop pulito), nomi separati da spazi o virgole, vuoto |
| `SBX_STOP_TIMEOUT` | `60` | secondi concessi allo stop delle sandbox prima di dockerd (`stop_grace_period` 120 s) |
| `SBX_KEYRING_PASS_FILE` | `/run/secrets/sbx/keyring_pass` | file della password nel container |

## Login Docker di sbx

`sbx login` è un login OAuth (Auth0): token d'accesso da 15 minuti e **refresh token che ruota** a ogni rinnovo. Conseguenze verificate:

- **Ogni istanza fa il proprio `sbx login`.** Due container con la stessa sessione (keyring copiato, backup ripristinato mentre l'originale gira) si invalidano a vicenda: il primo che rinnova rende vecchio il token dell'altro, che viene cancellato (`user is not authenticated to Docker: secret not found`).
- Dopo un restore (A, B o C) su un altro host: `sbx login` sul nuovo host. Le sandbox, i secret, le policy e tutto il resto restano; si rifà solo il login.
- Non tenere accesi insieme l'originale e la copia.

## Keyring

sbx tiene login e secret nel Secret Service. Nel container c'è `gnome-keyring` sulla sessione D-Bus di `alpine` (`unix:path=/run/user/1000/bus`), sbloccato con `keyring_pass`.

- **Password**: `SBX_SECRETS_DIR/keyring_pass`, fuori da `SBX_DATA` apposta: la sola cartella dati non apre il keyring. Senza quel file l'entrypoint ne genera una in `keyrings/.dind-env-keyring-pass` (avvio senza intervento, ma la copia dei dati diventa leggibile). Cambiare la password di un keyring esistente lo lascia bloccato: login e secret falliscono finché non si rimette quella vecchia.
- **Crash di gnome-keyring 46.1**: con più client insieme (avvio del daemon sbx, molte `sbx create` di fila) crasha (`gkd_secret_service_get_pkcs11_session: assertion 'client' failed`, poi abort). Il file di servizio D-Bus standard lo farebbe ripartire **bloccato**, e ogni `sbx create`, `sbx secret` o login fallirebbe con `the OS keychain is locked`. L'immagine sostituisce l'attivazione D-Bus (`org.freedesktop.secrets`, `org.gnome.keyring`) con `sbx-keyring-daemon`, che lo riavvia **sbloccato**: dopo un crash la richiesta successiva riesce (misurato: ~200 ms). Avvii e uscite in `/run/user/1000/gnome-keyring.log`.
- **mlock**: gnome-keyring tiene i segreti in memoria bloccata (non va in swap). Con il limite di default di Docker (8 MiB) la esaurisce in qualche ora (`couldn't allocate secure memory`) e continua in memoria normale: il compose alza `memlock`.

## Agent e configurazione

Tutto ciò che un agent scrive nella sandbox (config, plugin, skill, server MCP, sessioni) sta nel disco della VM o nei volumi persistenti del kit, entrambi in `sbx-state/`, e sopravvive a stop, riavvio del container e backup/restore.

Eccezioni dovute a sbx, non alla persistenza:

- **opencode**: il kit riscrive `~/.config/opencode/opencode.json` a ogni avvio della sandbox; le chiavi aggiunte a mano si perdono anche senza backup. Le personalizzazioni vanno nei file che il kit non tocca (es. `~/.config/opencode/` altri file, skill).
- **codex** (`~/.codex/config.toml`) e **copilot** (`~/.copilot/mcp-config.json`) vengono riscritti a ogni avvio ma il contenuto aggiunto resta.
- **claude**: `~/.claude/{projects,sessions,todos,shell-snapshots,statsig}` sono volumi persistenti del kit, il resto di `~/.claude` è nel rootfs.
- Con `--skills readwrite` (es. opencode) lo skill store globale è montato nella sandbox: le skill scritte lì compaiono in tutte le sandbox.
- **Server MCP locali** (`sbx mcp add --command ...`): girano nel container, non nella sandbox. Script e binari vanno sotto `/home/alpine` o nel workspace: quelli installati nell'immagine (`/usr/local`, `npm -g`, apt) spariscono quando il container viene ricreato, e A e B non salvano i percorsi di sistema.

## Porte

`sbx ports NAME --publish 127.0.0.1:18080:8080` (o `-p` alla create) pubblica la porta **dentro il container**. Per raggiungerla dall'host serve anche la riga `ports:` nel compose (es. `"127.0.0.1:18080:18080"`) e il publish su `0.0.0.0` dentro. Le porte pubblicate restano nella sandbox (`sandboxd/runtimes/ports/`) anche da ferma, ma `sbx ports` le mostra solo mentre gira.

## Backup e migrazione

Tre strategie in `sbx-backup-scripts/` (dettagli e variabili nei README di ciascuna):

| | **A: ricostruzione** | **B: copia raw dello stato sbx** | **C: copia a freddo dell'ambiente** |
|---|---|---|---|
| Cosa | una sandbox | tutto lo stato sbx | tutta `SBX_DATA` (sbx, Docker del container, home, keyring, workspace) |
| Dove gira | dentro il container (`/opt/sbx-backup-scripts/strategiaA`) | dentro il container | sull'host, accanto al compose |
| Fermo | quella sandbox | tutte le sandbox e il daemon sbx | tutto il container |
| Destinazione | qualsiasi sbx (anche sull'host, altro nome/workspace) | stessa versione sbx, stessa HOME | stesso compose/immagine, `SBX_DATA` ovunque |
| Verifica | per contenuto | per contenuto | **1:1** su ogni file (metadati, sha256, xattr) |

Login dopo il restore: con A e B serve un `sbx login` sulla destinazione (se c'è già, resta valido); con C il login copiato funziona finché l'originale resta spento. Mai originale e copia accesi insieme: il primo che rinnova il token slogga l'altro.

## Test

**Smoke test** (`tests/smoke.sbx.sh IMAGE [CYCLES]`, `just smoke-sbx TAG`, in pipeline su amd64 e arm64 prima di pubblicare i tag): avvio sotto tini, dockerd e daemon sbx, CLI che raggiunge il daemon, keyring sbloccato con la password del file e un item salvato, gnome-keyring di nuovo sbloccato dopo un `kill -9`, `memlock` illimitato, cartelle di sbx di `alpine`, i 6 script di backup, CYCLES `docker kill` con riavvio sugli stessi volumi (keyring e item conservati), stop pulito in meno di 60 s con sbx fermato prima di dockerd. Non crea sandbox, quindi non servono né `sbx login` né KVM: il daemon parte anche senza `/dev/kvm`, con un avviso. Ha trovato un bug: dopo un `docker kill` restava `sandboxd.pid`, e al riavvio quel PID poteva appartenere a un altro processo, così `sbx daemon start` aspettava 10 s e rinunciava (sbx giù dopo il secondo kill). Ora l'entrypoint lo rimuove all'avvio.

**Matrice manuale** con le sandbox, 29/10/2026, sbx v0.50.1. Più istanze di questo compose in parallelo (progetti `-tmp` con `SBX_DATA`, rete e porta propri), ognuna con il suo `sbx login`.

**Sorgente:** 11 sandbox, una per agent (claude, codex, copilot, cursor, devin, docker-agent, droid, gemini, kiro, opencode, shell), ognuna personalizzata:
- rootfs: marker, pacchetto apt, utente, `/opt`; config dell'agent; volumi del kit; variabili `-e`;
- Docker interno: immagine, volume, un container fermo e uno acceso;
- spec: workspace multipli e `:ro`, memoria, porte tcp4 e udp;
- sbx: secret della sandbox, globali, registry e client secret MCP; un server MCP locale (script sull'host), statico e caricato dopo la create; skill `readwrite` e dallo store; regole di rete della sandbox e globali; settings;
- per agent: claude con plugin e marketplace, MCP utente, `CLAUDE.md`, agent, comandi, skill, sessioni e todo; codex con MCP, `AGENTS.md` e skill; kiro con gli steering; opencode con `AGENTS.md` e skill.

**Verifica**, per ogni sandbox: 90 controlli funzionali eseguiti dentro la sandbox, più un'impronta completa (hash, permessi, owner e mtime di ogni file del filesystem; `sbx ls`, spec, porte, MCP, skill, secret, policy, settings; immagini, container, volumi e reti del Docker interno), confrontata con quella dell'origine.

| Prova | Da → a | Backup | Restore | Risultato |
|---|---|---|---|---|
| A, una sandbox alla volta | dindA → dindB (senza sandbox, suo login) | 12–72 s e 0,7–1,1G per sandbox | 12–40 s per sandbox | 90/90 identici; differenze attese (sotto) |
| B, stato sbx a freddo | dindA → dindD (stato e login già presenti, `EXISTING_STATE=move`) | 268 s, 13G | 534 s | 90/90 e impronta identici, tranne il login (non copiato) |
| C, tutto `SBX_DATA` | dindA → dindC | 234 s, 13G | circa 7 min | verifica 1:1 OK, 90/90 identici |
| Nuova immagine | dindC ricreato (`memlock`, script aggiornati) | — | — | 90/90 identici, login ancora valido, `ulimit -l` unlimited |
| C, finale con immagine nel backup | dindC (spento) → dinde | 275 s, 13G | 386 s (`docker load` compreso) | 1:1 OK su 2832 voci, 90/90 identici, login copiato funzionante senza `sbx login` |

Differenze attese:
- A: login Docker (non copiato); mtime arrotondati al secondo da `template save`, e con la data del restore per i file che il kit riscrive alla create (`/etc/hosts`, helper in `/usr/local/bin`, config degli agent, cartelle delle skill, `lost+found` dei volumi nuovi), sempre con lo stesso contenuto; un file in `~/.claude/backups/` scritto da Claude al primo avvio; il flag `(detached)` di `sbx ls`; il CA del proxy, che è dell'installazione di destinazione.
- Tutte: i kit riscrivono a ogni avvio alcune config (`opencode.json`, `mcp-config.json`, `settings.json` di gemini, `mcp.json` di kiro…) con lo stesso contenuto, quindi cambia solo l'mtime.

Bug trovati dalla matrice e corretti nella strategia A: secret registry non salvati; `create` fallita per un MCP statico senza il suo script host; MCP caricati dopo la create persi; config riscritte dal kit alla create perse (plugin, marketplace e MCP utente di claude, codex, gemini, kiro); porte `tcp4` diventate `tcp`; skill store ricreato 755 invece di 700. A e B ora salvano anche i file host dei server MCP locali.

Keyring durante i test: gnome-keyring è andato in crash più volte con molte `sbx create` di fila, ogni volta riavviato già sbloccato da `sbx-keyring-daemon` senza errori visibili; con `memlock: -1` niente più "couldn't allocate secure memory".

## Limiti

- Non si conservano (con nessuna strategia): processi e memoria delle sandbox avviate, la sessione `sbx login` con A e B (con C resta valida se l'originale è spento), le regole imposte dall'organizzazione (arrivano dal login), le chiavi a mano in `opencode.json`.
- Una sandbox pubblica porte dentro il container; verso l'host servono le righe `ports:` del compose.
- `privileged: true` è necessario per dockerd; sbx da solo funzionerebbe con `devices: [/dev/kvm]` e poche capability, ma questa immagine avvia sempre dockerd.
