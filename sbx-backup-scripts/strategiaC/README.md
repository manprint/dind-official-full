# Strategia C — copia a freddo dell'intero ambiente compose (sbx dentro dind)

Vale solo per l'ambiente `docker-compose.sbx.bind.yml` di dind-env-official, dove
sbx gira dentro il container e **ogni** dato persistente sta in bind mount sotto
una sola cartella, `SBX_DATA`. Il backup è la copia 1:1 di quella cartella a
container fermo; il restore la ricrea su un altro host (anche in un altro percorso)
e riavvia il container. Dentro il container i percorsi non cambiano
(`/home/alpine`, `/var/lib/docker`, workspace), quindi sbx ritrova tutto com'era.

| Cosa                                                              | Dove (sotto `SBX_DATA`)              | Copiato |
|-------------------------------------------------------------------|--------------------------------------|:-------:|
| Docker del container (immagini, container, volumi)                | `docker/`                            | sì |
| Home (dotfile, `~/.ssh`, backup A/B)                              | `home/`                              | sì |
| Tutte le sandbox: dischi VM, volumi persistenti degli agent (config, plugin, skill, sessioni), Docker interno di ogni sandbox | `sbx-state/` | sì |
| Spec, template, kit, registro MCP, skill store, audit             | `sbx-state/`                         | sì |
| Policy di rete/filesystem (governor.db)                           | `sbx-cache/`                         | sì |
| Settings (`sbx settings set`)                                     | `sbx-config/`                        | sì |
| Binding `sbx env`, dati client, secret di riserva, runtime        | `sbx-bindings/` `sbx-share/` `sbx-secrets/` `sbx-run/` | sì |
| Keyring: login Docker di sbx, `sbx secret`, client secret MCP     | `keyrings/`                          | sì (cifrato con la password del keyring) |
| Workspace (default `SBX_DATA/workspace`)                          | `workspace/`                         | sì |
| Password del keyring                                              | `SBX_SECRETS_DIR` (fuori, apposta)   | sì, cifrata gpg in `secrets.tar.gpg` |
| Immagine del container                                            | registry / `docker save`             | opzionale (`INCLUDE_IMAGE=1`) |

Non si conservano, come per A e B: processi e memoria delle sandbox (vengono
fermate), la sessione `sbx login` (v. sotto), regole imposte dall'organizzazione
(arrivano dal login).

## Quando usarla

- Ambiente compose sbx da spostare su un altro PC/server, o da salvare tutto insieme.
- Serve la garanzia 1:1: ogni file (metadati e contenuto) viene verificato.
- Si accetta di fermare il container (e quindi tutte le sandbox) durante la copia.

Per una singola sandbox → strategia A. Per sbx installato direttamente sull'host → B.

## Requisiti

- Host sorgente e destinazione: Docker con compose v2, `jq`, `tar`, `sha256sum`,
  `zstd` (se `COMPRESSOR=zstd`), `gpg` (se si salva la cartella secret).
- Stessa architettura e **stessa versione sbx** (stessa immagine): il restore avvisa
  se cambiano. KVM sull'host di destinazione.
- Spazio: `data.tar.zst` è molto più piccolo dello spazio apparente (i dischi VM
  sono sparse e la copia li tratta come tali).

## Backup

```bash
cd sbx-backup-scripts/strategiaC
# stesse variabili del compose (SBX_DATA, SBX_SECRETS_DIR, ...) o .env accanto al compose
ASSUME_YES=1 BACKUP_DIR=/srv/backup ./backup.sh
```

Passi dello script:

1. legge la configurazione risolta del compose (`docker compose config`) e ricava
   `SBX_DATA`, cartella secret, workspace e immagine;
2. `docker compose stop`: l'entrypoint ferma le sandbox (`SBX_STOP_TIMEOUT`),
   poi il daemon sbx, poi dockerd;
3. un container usa-e-getta della stessa immagine, come root e con
   `CAP_SYS_ADMIN` (senza, gli xattr `trusted.*` dei layer overlay non si leggono
   e tar li perde in silenzio), copia `SBX_DATA` (`tar` sparse, owner numerici,
   xattr, ACL) e scrive `MANIFEST.txt`: per ogni voce tipo, permessi, owner,
   dimensione (non per le cartelle: su ext4 dipende dalla storia delle voci),
   mtime, destinazione dei link, sha256 del contenuto e degli xattr;
4. riavvia il container (`RESTART_AFTER=1`) e le sandbox che giravano
   (con `SBX_AUTOSTART=previous`);
5. cifra la cartella secret (password del keyring) con gpg, letta tramite il
   container usa-e-getta (la cartella può essere di root);
6. impacchetta tutto in **un solo file** `sbxC-<container>-<data>.tar` con `SHA256SUMS`.

Variabili principali (in testa allo script):

| Variabile | Default | Significato |
|---|---|---|
| `COMPOSE_FILE` / `COMPOSE_PROJECT` | compose del repo / default | ambiente da salvare |
| `BACKUP_DIR` | `~/sbx-backups` | destinazione (non dentro `SBX_DATA`) |
| `INCLUDE_WORKSPACE` | `1` | workspace se sta fuori da `SBX_DATA` |
| `INCLUDE_SECRETS_DIR` | `1` | password del keyring, cifrata |
| `SECRETS_PASSPHRASE_FILE` | vuoto | passphrase gpg da file (vuoto = interattiva) |
| `INCLUDE_IMAGE` | `0` | `docker save` dell'immagine (host senza registry) |
| `COMPRESSOR` | `zstd` | `zstd`, `gzip`, `none` |
| `ASSUME_YES` | `0` | niente conferma prima dello stop |
| `WRITE_MANIFEST` | `1` | elenco per la verifica 1:1 |

## Restore

```bash
# sul nuovo host: repo dind-env-official + .env con il nuovo SBX_DATA ecc.
cd sbx-backup-scripts/strategiaC
SBX_DATA=/srv/sbx SBX_SECRETS_DIR=/srv/sbx-secrets ./restore.sh /srv/backup/sbxC-dind-env-sbx-20261029-101500.tar
```

Passi dello script:

1. verifica `SHA256SUMS`; si ferma se il container esiste già o se `SBX_DATA`
   non è vuota (`EXISTING=move` la rinomina);
2. immagine: usa quella del compose; se manca la carica da `image.tar` o la scarica;
   avvisa se è diversa dall'originale o se la versione sbx cambia;
3. estrae `data.tar` come root in `SBX_DATA` (sparse, owner, xattr, ACL);
4. **verifica 1:1**: ricalcola il manifest e lo confronta con `MANIFEST.txt`;
   alla prima differenza si ferma e lascia i due manifest per l'analisi;
5. workspace esterno e cartella secret, solo se le destinazioni sono vuote;
6. `docker compose up -d`, attende lo stato healthy, mostra `sbx ls` (se
   risponde `not signed in to Docker`: `sbx login`, v. *Considerazioni*).

| Variabile | Default | Significato |
|---|---|---|
| `EXISTING` | `abort` | `SBX_DATA` non vuota: `abort` o `move` |
| `VERIFY` | `1` | confronto 1:1 con il manifest |
| `LOAD_IMAGE` | `auto` | `image.tar`: `auto` (se manca), `always`, `never` |
| `RESTORE_WORKSPACE` / `RESTORE_SECRETS_DIR` | `1` | ripristina workspace esterno / password keyring |
| `START_AFTER` | `1` | avvia il container alla fine |
| `HEALTH_TIMEOUT` | `300` | attesa dello stato healthy |
| `WORK_DIR` | accanto a `SBX_DATA` | appoggio per l'estrazione (stesso disco: serve spazio) |

## Considerazioni

- **Percorso del workspace dentro il container** (`SBX_WORKSPACE_PATH`): le sandbox
  lo registrano e Claude Code ci lega la history. Deve restare uguale; il restore
  avvisa se il compose di destinazione ne usa uno diverso. Il percorso host può cambiare.
- **Porte**: le porte pubblicate dalle sandbox restano nella spec; quelle verso
  l'host passano dalle righe `ports:` del compose, da riportare sul nuovo host.
- **Login Docker di sbx**: è OAuth con refresh token che ruota a ogni rinnovo
  (ogni 15 minuti). La copia contiene il login e funziona finché l'originale
  resta spento (verificato: restore con l'originale fermo, nessun `sbx login`); se girano entrambi, il primo che rinnova slogga l'altro
  (`secret not found`). Migrazione: originale spento, poi restore. Copia di
  prova accanto all'originale: `docker exec -it <container> sbx login` sulla
  copia. In entrambi i casi sandbox, secret, policy, MCP e skill restano; al
  massimo si rifà il login.
- **Password del keyring**: è fuori da `SBX_DATA` apposta, così la sola cartella
  dati non apre il keyring. Senza la password (né `secrets.tar.gpg`) il login e i
  secret sbx vanno rifatti. Se manca del tutto, l'entrypoint ne genera una
  dentro `keyrings/` (comodo, ma la copia dei dati diventa leggibile).
- **Tempo di fermo**: proporzionale ai dati reali (dischi sparse letti solo dove
  pieni). Per ridurlo si può lanciare prima `strategiaB` con `TRIM_DIND_BEFORE_STOP`
  dentro il container, o fare `fstrim` nelle sandbox.
- **Rete del compose**: subnet e IP del container sono nel compose, non nel backup;
  due istanze sullo stesso host richiedono `DIND_NET_SUBNET`, `DIND_IPV4`,
  `DIND_TLS_PORT` e `DIND_NAME` diversi.
- Il backup contiene il keyring cifrato e, cifrata a parte, la sua password:
  trattare il file come un segreto e non mettere la passphrase gpg accanto.
