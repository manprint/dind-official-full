# Backup e migrazione Docker Sandboxes (sbx)

Tre tecniche per salvare sandbox sbx e ripristinarle su un altro PC.
`sbx template save/load` da solo **non basta**: salva solo il rootfs e perde la history di Claude, il Docker interno, le credenziali e la configurazione.
A e B valgono per sbx installato sull'host e per sbx dentro il container di `docker-compose.sbx.bind.yml` (gli script sono anche nell'immagine, in `/opt/sbx-backup-scripts`). C vale solo per quel container.

| | **A: ricostruzione** | **B: copia raw 1:1** |
|---|---|---|
| Cosa salva | **una** sandbox: rootfs, `~/.claude` (history, memory, sessioni), Docker interno, credenziali, workspace (opzionale) | **tutto** lo stato sbx: tutte le sandbox, template, policy, spec + credenziali, workspace (opzionale) |
| Come | comandi ufficiali: `template save/load`, `exec`, `create` | `tar --sparse` delle cartelle interne di sbx |
| Risultato | sandbox nuova, contenuto equivalente, nuovo ID | clone identico, stesso ID |
| Fermo | solo quella sandbox, pochi secondi (snapshot rootfs) | **tutte** le sandbox + daemon, per tutta la copia |
| PC destinazione | qualsiasi OS e utente; nome e workspace modificabili | Linux, stessa arch, **stessa versione sbx**, **stessa HOME**, stessi percorsi workspace |
| Robustezza tra versioni sbx | alta | bassa (formato interno non documentato) |
| Policy di rete, porte | da riapplicare a mano (salvate in `metadata/`) | incluse |

## Quale usare

- **A** se il PC nuovo ha un OS, un utente o una versione sbx diversi, se vuoi spostare **una sola** sandbox, o se non puoi fermare le altre. È la scelta di default.
- **B** se passi da Linux a Linux con lo stesso utente (stessa HOME), la stessa versione sbx e gli stessi percorsi, e vuoi un clone esatto di tutto.
- **Migrazione importante:** falle **entrambe**, ripristina con B e tieni A come rete di sicurezza.

## Uso

```bash
# Strategia A
cd strategiaA
./backup.sh <sandbox>                         # → ~/sbx-backups/sbxA-<sandbox>-<data>.tar
./restore.sh ~/sbx-backups/sbxA-<sandbox>-<data>.tar

# Strategia B
cd strategiaB
./backup.sh                                   # → ~/sbx-backups/sbxB-full-<host>-<data>.tar.zst
./restore.sh ~/sbx-backups/sbxB-full-<host>-<data>.tar.zst
```

Ogni backup è **un solo file**. La configurazione è in testa a ogni script e si può sovrascrivere da ambiente, ad esempio `ASSUME_YES=1 BACKUP_DIR=/media/usb ./backup.sh`.
Dettagli, variabili e procedura manuale: [strategiaA/README.md](strategiaA/README.md), [strategiaB/README.md](strategiaB/README.md).

**Strategia C** (solo per il container `docker-compose.sbx.bind.yml`, dall'host): copia a freddo dell'intera cartella `SBX_DATA` (sbx, Docker del container, home, keyring, workspace) con verifica 1:1 di ogni file. Vedi [strategiaC/README.md](strategiaC/README.md).

```bash
cd strategiaC
ASSUME_YES=1 BACKUP_DIR=/srv/backup ./backup.sh             # → sbxC-<container>-<data>.tar
SBX_DATA=/srv/sbx SBX_SECRETS_DIR=/srv/sbx-secrets ./restore.sh /srv/backup/sbxC-....tar
```

## Considerazioni

- **Credenziali:** sbx le tiene nel **keyring di sistema**, non su disco. Entrambi gli script le esportano **cifrate con gpg** (passphrase interattiva oppure `SECRETS_PASSPHRASE_FILE`). Non conservare la passphrase insieme al backup.
- **OAuth Anthropic copiato:** il token vale su entrambi i PC, ma la rotazione può invalidarne uno. Dopo la migrazione usa la sandbox su **un solo** PC.
- **Login Docker di sbx:** è OAuth con refresh token che ruota a ogni rinnovo (ogni 15 minuti). Una copia del login vale finché uno dei due lati non rinnova, poi l'altro viene sloggato (`secret not found`). Per questo A e B non lo copiano di default: **sul PC nuovo esegui `sbx login`** (se lì sbx è già loggato, quel login resta). C copia anche il login, che funziona finché l'originale resta spento. In ogni caso non tenere accesi insieme originale e copia.
- **Workspace** (es. `/mnt/data/Git`): non è dentro la sandbox. Includilo (`INCLUDE_WORKSPACE[S]=1`) oppure copialo a parte con rsync o git, **nello stesso percorso assoluto**. Così la history di Claude si ricollega da sola. Con A, se cambi percorso, le cartelle dei progetti vengono rinominate, ma le impostazioni per progetto in `~/.claude.json` vanno riconfermate.
- **Docker interno** delle sandbox: A con `DIND_MODE=raw` (default), B e C copiano tutto `/var/lib/docker`, container compresi. Con A e `DIND_MODE=export` si salvano solo immagini e volumi: i container vanno ricreati.
- **RAM:** con A, se il PC nuovo ha meno memoria, imposta `MEMORY=...` (massimo il 75% della RAM host).
- **Spazio:** A richiede circa 2 volte il rootfs usato. B richiede circa la dimensione reale dello stato; il `fstrim` che lo script esegue da solo la riduce (in un caso reale da 48G a 25G).
- **Sicurezza:** nessuno script cancella o sovrascrive sandbox o stato esistenti. Il restore si ferma, oppure con B e `EXISTING_STATE=move` sposta da parte lo stato precedente. Il PC sorgente resta intatto.
- **Prima di dismettere il PC vecchio:** fai il restore, verifica con `sbx ls`, `sbx secret ls` e `sbx run --name <sandbox>`, controlla che la history di Claude ci sia.

## Stato dei test (29/10/2026, sbx v0.50.1)

Matrice completa nei container di `docker-compose.sbx.bind.yml`: 11 sandbox, una per agent, migrate con A, B e C e confrontate file per file con l'origine (dettagli in [README_SBX.md](../README_SBX.md#test) e nei README delle strategie).
- **A:** 90/90 controlli identici, contenuto e permessi di ogni file identici (tranne il CA del proxy); differenze solo attese (login, mtime dei file riscritti dal kit alla create, flag `detached`).
- **B:** 90/90 controlli e impronta identici, tranne il login (non copiato).
- **C:** verifica 1:1 di ogni file di `SBX_DATA`, 90/90 controlli identici, login copiato funzionante con l'originale spento.
- Su un host con sandbox in uso B non è stata eseguita, perché le avrebbe fermate. Alla prima esecuzione reale va osservata.
