# Istanze Incus con gli script bash

Guida operativa agli script `create_incus_<distro>.sh`: cosa fanno, tutte le impostazioni, come si cambia un'istanza dopo la creazione, backup e restore. Il container `incus-env` (immagine `-incus`) è descritto in [README_INCUS.md](README_INCUS.md); lo stesso lavoro fatto con OpenTofu è in [incus_by_terraform.md](incus_by_terraform.md).

I comandi `incus …` si lanciano **dentro il container**, come `alpine`:

```bash
docker exec -it incus-env bash          # poi: incus list, /opt/incus-template/..., ecc.
```

Le misure citate vengono da un container `incus-env` (Incus 7.5.1, pool `dir`) su un host Linux 7.0 con cgroup v2.

## 1. Gli script

| Script | Immagine di default | Utente | Init | Pacchetti | Docker |
|---|---|---|---|---|---|
| `create_incus_alpine.sh` | `images:alpine/3.24` | `alpine` | OpenRC | `apk` | `docker` + `docker-cli-compose` (sempre quelli di Alpine) |
| `create_incus_debian13.sh` | `images:debian/13` | `debian` | systemd | `apt` | `docker-ce` dal repository ufficiale; ripiego `docker.io` + `docker-compose` |
| `create_incus_ubuntu2404.sh` | `images:ubuntu/24.04` | `ubuntu` | systemd | `apt` | `docker-ce`; ripiego `docker.io` + `docker-compose-v2` |
| `create_incus_ubuntu2604.sh` | `images:ubuntu/26.04` | `ubuntu` | systemd | `apt` | `docker-ce`; ripiego `docker.io` + `docker-compose-v2` |
| `create_incus_fedora.sh` | `images:fedora/44` | `fedora` | systemd | `dnf` | `docker-ce`; ripiego `moby-engine` + `docker-compose` |

| Dove | Percorso |
|---|---|
| Nell'immagine | `/opt/incus-template/` (proprietà `alpine`, eseguibili) |
| Nel repository | `scripts/` |
| Altrove | si copiano su qualunque macchina con il client `incus` (v. *Server remoto*) |

Uno script crea **una** istanza e la configura una volta sola. Dopo la creazione non serve più: le modifiche si fanno con `incus config …` (sezione 6). Rilanciato su un'istanza che esiste già, lo script si rifiuta.

## 2. Uso rapido

```bash
/opt/incus-template/create_incus_alpine.sh                                  # tutto di default: alpine-dev
INSTANCE_NAME=web INSTANCE_MEMORY=4GiB INSTANCE_IPV4=10.10.200.50 \
  USER_PASSWORD=segreta /opt/incus-template/create_incus_debian13.sh
INSTANCE_NAME=api INSTANCE_SWAP=1GiB INSTANCE_SSH_PUBLISH_PORT=2222 \
  EXTRA_PACKAGES="tmux procps-ng" /opt/incus-template/create_incus_alpine.sh
```

Le impostazioni si danno come variabili d'ambiente sulla riga di comando. In alternativa si cambiano i default nella testata di una **copia** dello script (`: "${VAR:=default}"`).

La riga finale riassume il risultato:

```text
[create_incus_alpine] ready: web  ip=10.10.200.50  user=alpine  password=segreta
[create_incus_alpine] ssh alpine@10.10.200.50   (or port 2222 of the incus host)
```

Tempi indicativi: da ~20 s (Alpine, immagine in cache) a qualche minuto (Fedora), secondo la rete e i mirror.

## 3. Variabili

### Istanza

| Variabile | Default | Cosa fa | Diventa | Cambiarla dopo |
|---|---|---|---|---|
| `INCUS_REMOTE` | vuoto | remote del client `incus`; vuoto = il daemon locale | prefisso `REMOTE:` | — |
| `INSTANCE_NAME` | `<distro>-dev` | nome dell'istanza, anche hostname | nome + `/etc/hostname` | `incus rename` a istanza ferma + hostname nel guest (§6) |
| `INSTANCE_IMAGE` | v. tabella §1 | immagine | `incus launch IMMAGINE` | non si cambia: ricreare |
| `INSTANCE_PROFILES` | `default` | profili, separati da spazio | `-p` | `incus profile add/remove` |
| `INSTANCE_STORAGE_POOL` | vuoto (quello del profilo) | pool del disco root | `-s POOL` | `incus move NOME --storage POOL` a istanza ferma (non provato) |
| `INSTANCE_NETWORK` | vuoto (quella del profilo) | rete gestita di `eth0` | `-n RETE` | `incus config device set/override NOME eth0 network=…` |
| `INSTANCE_IPV4` | vuoto (DHCP) | IPv4 fisso su quella rete | device `eth0` con `ipv4.address` | §6 |
| `INSTANCE_MEMORY` | `2GiB` (vuoto = nessun limite) | RAM massima | `limits.memory` | a caldo |
| `INSTANCE_CPU` | `2` (vuoto = nessun limite) | CPU: numero (`2`) o insieme (`0-3`) | `limits.cpu` | a caldo |
| `INSTANCE_SWAP` | vuoto (nessuna swap) | swap usabile: `512MiB`, `1GiB`…; `0`/`off`/`none`/`no` = nessuna | `raw.lxc: lxc.cgroup2.memory.swap.max = <byte>`; `0` → `limits.memory.swap=false` | dal riavvio (§6) |
| `INSTANCE_DISK_SIZE` | vuoto | dimensione del disco root | device `root` con `size` | solo pool btrfs/lvm/zfs; sul pool `dir` (default) non ha effetto |
| `INSTANCE_NESTING` | `true` | container annidati (Docker) | `security.nesting` | dal riavvio |
| `INSTANCE_INTERCEPT` | `true` | `mknod`, `setxattr`, `sysinfo` emulati dal daemon | `security.syscalls.intercept.*` | dal riavvio; **senza effetto se privilegiata** |
| `INSTANCE_PRIVILEGED` | `false` | root dell'istanza = root del container | `security.privileged` | dal riavvio (rimappa gli uid, §6) |
| `INSTANCE_AUTOSTART` | `true` | riparte con Incus (reboot, crash) | `boot.autostart` | a caldo |
| `INSTANCE_CONFIG` | vuoto | altre chiavi `chiave=valore`, separate da spazio, applicate per ultime | `-c chiave=valore` | `incus config set` |
| `INSTANCE_SSH_PUBLISH_PORT` | vuoto | porta del container `incus-env` inoltrata alla 22 dell'istanza | device `proxy` `ssh` | `incus config device set NOME ssh listen=tcp:0.0.0.0:PORTA` |
| `INSTANCE_RECREATE` | `false` | `true` **cancella** un'istanza con lo stesso nome e la rifà | `incus delete --force` | — |
| `WAIT_NETWORK_SECONDS` | `90` | attesa della rete/DNS (risoluzione del mirror) prima di installare | — | — |

### Guest (usate una volta, alla creazione)

| Variabile | Default | Cosa fa | Cambiarla dopo, dentro l'istanza |
|---|---|---|---|
| `USER_NAME` | `alpine`/`debian`/`ubuntu`/`fedora` | utente creato (non `root`) | `usermod -l` (a mano) |
| `USER_UID` | `1000` | uid e gid dell'utente | `usermod -u` / `groupmod -g` |
| `USER_PASSWORD` | `password` | password (ssh, sudo) | `passwd UTENTE` |
| `USER_SHELL` | `/bin/bash` | shell di login | `chsh` / `usermod -s` |
| `USER_SUDO` | `true` | gruppo `sudo` (Debian/Ubuntu) o `wheel` (Alpine/Fedora) | `usermod -aG` / `gpasswd -d` |
| `USER_SUDO_NOPASSWD` | `false` | sudo senza password | file in `/etc/sudoers.d/` (§6) |
| `TIMEZONE` | `Europe/Rome` | fuso orario | `ln -sf /usr/share/zoneinfo/ZONA /etc/localtime` |
| `LOCALE` | `it_IT.UTF-8` | `LANG`, `LC_ALL`, `LANGUAGE` (Fedora: anche il `glibc-langpack`) | file in `/etc/profile.d/` / `update-locale` |
| `KEYMAP` | `it` | tastiera (`/etc/default/keyboard`, `vconsole.conf` tranne Alpine) | file stessi |
| `SSH_PASSWORD_AUTH` | `yes` | `PasswordAuthentication` | `/etc/ssh/sshd_config.d/10-template.conf` + riavvio di sshd |
| `SSH_PERMIT_ROOT` | `no` | `PermitRootLogin`: `yes`, `no`, `prohibit-password` | idem |
| `INSTALL_DOCKER` | `true` | Docker + Compose, utente nel gruppo `docker` | installazione a mano |
| `DOCKER_SOURCE` (non Alpine) | `official` | `official` (download.docker.com) o `distro` | — |
| `DOCKER_LOG_MAX_SIZE` / `DOCKER_LOG_MAX_FILE` | `10m` / `5` | rotazione dei log in `/etc/docker/daemon.json` | il file + riavvio di Docker |
| `INSTALL_NET_TOOLS` | `true` | `tcpdump`, `nmap`, `mtr`, `iperf3`, `dig`, `ss`, `conntrack`, `nft`… | gestore pacchetti |
| `INSTALL_RCLONE` | `true` | rclone ufficiale con checksum verificato, `user_allow_other` | — |
| `RCLONE_RELEASE` | `current` | versione di rclone (es. `v1.70.0`). Non `RCLONE_VERSION`: rclone la legge come `--version` | `rclone selfupdate` |
| `EXTRA_PACKAGES` | vuoto | altri pacchetti della distro, separati da spazio | gestore pacchetti |

### Cosa installa sempre

| Gruppo | Contenuto |
|---|---|
| Base | bash, bash-completion, sudo, ssh server e client, curl, wget, git, vim, nano, rsync, unzip, jq, htop, lsof, fuse/fuse3 |
| Shell | `alias ll='ls -alFh'` per tutti gli utenti (login e non); completamento bash anche per root |
| Alpine | servizio OpenRC `cgroup-delegate` (prima di Docker): senza, `docker run -m/--cpus` fallisce |
| Ubuntu | toglie `/etc/sudoers.d/90-incus`, il sudo senza password che l'immagine dà a `ubuntu` |

## 4. Cosa fa lo script, in ordine

| Passo | Dettaglio | Se fallisce |
|---|---|---|
| 1. Controlli | client `incus` presente, daemon raggiungibile, `USER_NAME` non `root`, `INSTANCE_SWAP` valida | si ferma prima di creare nulla |
| 2. Istanza esistente | errore, o cancellazione con `INSTANCE_RECREATE=true` | — |
| 3. `incus launch` | immagine, profili, limiti, swap, sicurezza, `INSTANCE_CONFIG`, disco e `eth0` | nessuna istanza |
| 4. Device `ssh` | solo con `INSTANCE_SSH_PUBLISH_PORT` | l'istanza resta |
| 5. Attesa rete | fino a `WAIT_NETWORK_SECONDS` | l'istanza resta, senza provisioning |
| 6. Provisioning | script spinto in `/root/provision.sh`, eseguito con le impostazioni del guest, poi rimosso | l'istanza resta a metà: ispezionala, poi ricreala con `INSTANCE_RECREATE=true` |
| 7. Riga finale | nome, IP di `eth0`, utente, password, comando ssh | — |

## 5. Accedere all'istanza

| Da dove | Come | Note |
|---|---|---|
| Container `incus-env` | `incus exec NOME -- su - UTENTE` | shell dell'utente |
| Container `incus-env` | `incus shell NOME` | shell di root (alias `exec … -- su -l`) |
| Container `incus-env` | `ssh UTENTE@IP` | IP sul bridge `incusbr0` (`incus list`) |
| Host | `ssh -p PORTA UTENTE@127.0.0.1` | serve `INSTANCE_SSH_PUBLISH_PORT=PORTA` **e** la stessa porta pubblicata nel compose: `ports: - "127.0.0.1:2222:2222"` |
| Host o browser | web UI `http://localhost:8080/` | console e terminale delle istanze |
| Copia file | `incus file push FILE NOME/percorso`, `incus file pull NOME/percorso .` | |

Il device `proxy` ascolta nel container `incus-env`, non sull'host: senza la riga `ports:` la porta resta interna. Lo stesso vale per ogni altro inoltro (§6).

## 6. Modificare un'istanza esistente

Gli script non gestiscono le istanze dopo la creazione: si usa il client. `NOME` = nome dell'istanza.

### Risorse e sicurezza

| Cosa | Comando | Quando vale |
|---|---|---|
| RAM | `incus config set NOME limits.memory=4GiB` | subito (misurato) |
| CPU | `incus config set NOME limits.cpu=4` | subito |
| Swap | `incus config set NOME raw.lxc="lxc.cgroup2.memory.swap.max = $((2*1024*1024*1024))"` | dal riavvio |
| Togliere la swap | `incus config unset NOME raw.lxc` (o `limits.memory.swap=false`) | dal riavvio |
| Privilegiata ↔ no | `incus config set NOME security.privileged=false` | dal riavvio: Incus rimappa gli uid del filesystem (3–4 s misurati su un'Alpine con Docker; di più su istanze grandi) |
| Nesting / intercept | `incus config set NOME security.nesting=true`, `security.syscalls.intercept.sysinfo=true` | dal riavvio |
| Autostart | `incus config set NOME boot.autostart=false` | subito |
| Ordine all'avvio | `boot.autostart.priority=10` (più alto = prima), `boot.autostart.delay=5` (secondi dopo di lei) | al prossimo avvio di Incus |
| Tempo di spegnimento | `boot.host_shutdown_timeout=60` (default 30 s) | al prossimo stop di `incus-env`; v. *Budget di tempo allo stop* in README_INCUS |
| Processi massimi | `incus config set NOME limits.processes=500` | subito |

- **Sintassi.** Usa sempre `chiave="valore"`. Con la forma deprecata a spazio (`raw.lxc "… = N"`) Incus prende l'`=` del valore come separatore e rifiuta (*unknown key*).
- **`raw.lxc` è una chiave sola.** `set` la riscrive tutta: se contiene altre righe (`incus config get NOME raw.lxc`), rimettile insieme, una per riga.
- **Riavvio:** `incus restart NOME`.
- RAM e swap, e cosa mostrano `free`/`htop`: *[Gestione RAM e swap](README_INCUS.md#gestione-ram-e-swap)*.

### Rete, porte, cartelle condivise

| Cosa | Comando | Note |
|---|---|---|
| IP fisso (istanza creata con `INSTANCE_IPV4`) | `incus config device set NOME eth0 ipv4.address=10.10.200.51` | poi `incus restart NOME` |
| IP fisso (`eth0` dal profilo) | `incus config device override NOME eth0 ipv4.address=10.10.200.51` | `override` copia il device del profilo nell'istanza; `set` vale solo se il device è già dell'istanza |
| Tornare al DHCP | `incus config device unset NOME eth0 ipv4.address` | |
| Porta ssh pubblicata | `incus config device set NOME ssh listen=tcp:0.0.0.0:2223` | e `ports:` nel compose |
| Aggiungere la porta ssh | `incus config device add NOME ssh proxy listen=tcp:0.0.0.0:2222 connect=tcp:127.0.0.1:22` | |
| Inoltrare un'altra porta | `incus config device add NOME web proxy listen=tcp:0.0.0.0:8081 connect=tcp:127.0.0.1:80` | e `ports:` nel compose |
| Cartella condivisa | `incus config device add NOME data disk source=/home/alpine/shared path=/data shift=true` | `source` è un percorso **del container**: `/home/alpine` è `ALPINE_HOME` sull'host |
| Togliere un device | `incus config device remove NOME data` | |

`shift=true` serve nelle istanze non privilegiate. Senza, i file dell'utente 1000 compaiono come `65534` e l'utente non può scriverci (*Permission denied*). Con `shift=true` compaiono come 1000 e la scrittura funziona (misurato).

Per condividere un percorso dell'host fuori da `ALPINE_HOME`, prima aggiungilo come volume al container nel compose.

### Nome, disco, utente, pacchetti

| Cosa | Comando |
|---|---|
| Rinominare | `incus stop NOME && incus rename NOME NUOVO && incus start NUOVO`, poi hostname nel guest: `incus exec NUOVO -- sh -c 'echo NUOVO > /etc/hostname; hostname NUOVO'`. Con l'istanza accesa: *Renaming of running instance not allowed* |
| Dimensione del disco | `incus config device override NOME root size=20GiB`: vale solo su pool btrfs/lvm/zfs. Sul pool `dir` viene accettata ma non limita nulla (`df` mostra il filesystem dell'host) |
| Spostare su un altro pool | `incus stop NOME && incus move NOME --storage POOL` (non provato) |
| Password | `incus exec NOME -- passwd UTENTE` |
| sudo senza password | Alpine/Fedora: `echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/wheel`; Debian/Ubuntu: `echo 'UTENTE ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/UTENTE` (dentro l'istanza, `chmod 0440`) |
| Pacchetti | `incus exec NOME -- apk add …` / `apt-get install …` / `dnf install …` |
| Aggiornare il guest | `incus exec NOME -- apk upgrade` / `apt-get update && apt-get upgrade` / `dnf upgrade`; meglio dopo uno snapshot (§8) |
| Log dell'istanza | `incus info NOME --show-log` |

### Ciclo di vita

| Cosa | Comando |
|---|---|
| Stato, IP | `incus list`, `incus info NOME` |
| Fermare / avviare / riavviare | `incus stop NOME`, `incus start NOME`, `incus restart NOME` |
| Cancellare | `incus delete -f NOME`: cancella anche tutti i suoi snapshot |
| Ricreare da zero | stesso comando dello script con `INSTANCE_RECREATE=true`: **cancella l'istanza e i suoi dati** |

## 7. Modificare gli script

| Cosa | Come |
|---|---|
| Cambiare i default | copia lo script (`cp /opt/incus-template/create_incus_alpine.sh ~/`) e modifica la testata. `/opt` sta nello strato del container e va perso quando lo ricrei; la home no |
| Cambiare il provisioning | il blocco tra `<<'GUEST'` e `GUEST` è lo script eseguito nell'istanza, in `sh`. Le impostazioni gli arrivano come variabili d'ambiente (`--env` in fondo allo script): una variabile nuova va aggiunta lì |
| Nel repository | i cinque script sono duplicati di proposito (ognuno si copia da solo): una modifica va riportata negli altri. `guest/<distro>.sh` del template OpenTofu è lo stesso blocco: `tests/terraform.sh --fix` lo riallinea |
| Provare | `tests/templates.sh IMMAGINE [template…]` con `SCRIPTS_DIR=scripts` (serve internet) |

## 8. Backup e restore

### Quale strumento

| Strumento | Cosa salva | Istanza accesa? | Dove finisce | Sopravvive a `incus delete`? | Ripristino |
|---|---|---|---|---|---|
| **Snapshot** | filesystem + configurazione, in un istante | sì | nel pool, accanto all'istanza | **no**: `delete` cancella anche gli snapshot | `incus snapshot restore` |
| **Export** | istanza (e di default i suoi snapshot) in un `.tar.gz` | sì | un file a scelta, es. in `/home/alpine/backups` (= `ALPINE_HOME/backups` sull'host) | sì | `incus import` |
| **Copy** | un clone completo | sì | nello stesso Incus | sì (è un'altra istanza) | è già pronta |
| **Publish** | solo il filesystem, come immagine (niente limiti, device, IP) | da uno snapshot | archivio immagini di Incus | sì | `incus launch IMMAGINE NUOVA` |
| **Backup a freddo dell'ambiente** | tutto: database Incus, immagini, istanze, snapshot, home di `alpine` | no: `incus-env` fermo | un archivio dei due bind mount | sì | si estrae e si riavvia il container |

Uno snapshot non è un backup: sta sullo stesso disco e muore con l'istanza. Per i backup veri usa export o il backup a freddo, e copia i file **fuori** dall'host.

### Snapshot

| Cosa | Comando | Note (misurate) |
|---|---|---|
| Creare | `incus snapshot create NOME prima-di-upgrade` | senza nome: `snap0`, `snap1`… |
| Elencare | `incus snapshot list NOME` | |
| Ripristinare | `incus snapshot restore NOME prima-di-upgrade` | l'istanza accesa viene fermata e riavviata (~2 s). Torna **anche la configurazione** di allora: un `limits.memory` cambiato dopo lo snapshot torna al valore vecchio. Docker e i container `unless-stopped` ripartono |
| Cancellare | `incus snapshot delete NOME prima-di-upgrade` | |
| Rinominare | `incus snapshot rename NOME vecchio nuovo` | |
| Recuperare un file solo | `sudo cat /var/lib/incus/storage-pools/default/containers-snapshots/NOME/SNAP/rootfs/percorso > file`, poi `incus file push file NOME/percorso` | senza ripristinare tutta l'istanza |
| Clonare da uno snapshot | `incus copy NOME/SNAP NUOVA` | v. *Copy* sotto per i conflitti |
| Snapshot con la memoria (`--stateful`) | non disponibile | serve CRIU, che l'immagine non ha (*Stateful snapshots require … migration.stateful*) |

Snapshot automatici:

| Chiave | Esempio | Effetto |
|---|---|---|
| `snapshots.schedule` | `@daily`, `@hourly`, `0 3 * * *` | quando farli (cron) |
| `snapshots.expiry` | `7d`, `4w` | dopo quanto cancellarli |
| `snapshots.pattern` | `auto-%d` | nome (`%d` = numero progressivo) |
| `snapshots.schedule.stopped` | `false` | anche per le istanze ferme? |

```bash
incus config set NOME snapshots.schedule="@daily" snapshots.expiry=7d snapshots.pattern="auto-%d"
```

### Export e import

```bash
mkdir -p ~/backups
incus export NOME ~/backups/NOME-$(date +%F).tar.gz                  # con gli snapshot
incus export NOME ~/backups/NOME-$(date +%F).tar.gz --instance-only  # senza: metà dimensione nel test
```

| Opzione di `export` | Effetto |
|---|---|
| (nessuna) | istanza e tutti i suoi snapshot (misurato: 274 MB per un'Alpine con Docker e uno snapshot) |
| `--instance-only` | solo lo stato attuale (137 MB) |
| `--optimized-storage` | formato del driver (btrfs/zfs): più veloce, si importa solo sullo stesso driver; inutile sul pool `dir` |
| `--compression none` | niente gzip: più veloce, file più grande |

Durante l'export Incus prepara l'archivio in `/var/lib/incus/backups` prima di passarlo al client: serve spazio libero per **due copie**, una lì e una nella destinazione.

| Ripristino | Comandi | Cosa succede (misurato) |
|---|---|---|
| Stessa istanza, persa o rovinata | `incus delete -f NOME` (se c'è ancora), `incus import FILE.tar.gz`, `incus start NOME` | torna `STOPPED`: va avviata. Tornano IP fisso, device, limiti, swap, snapshot; Docker e i suoi container ripartono |
| Una seconda istanza dallo stesso backup | `incus import FILE.tar.gz NUOVA`, poi la tabella sotto, poi `incus start NUOVA` | senza correzioni non parte: *MAC address … already defined on another NIC* |

Prima di avviare una seconda istanza nata da un backup, togli quello che resterebbe in conflitto con l'originale:

| Conflitto | Correzione |
|---|---|
| MAC di `eth0` | `incus config unset NUOVA volatile.eth0.hwaddr` (Incus ne genera uno nuovo) |
| IP fisso | `incus config device set NUOVA eth0 ipv4.address=ALTRO_IP` |
| Porta ssh pubblicata | `incus config device set NUOVA ssh listen=tcp:0.0.0.0:ALTRA_PORTA` |
| Hostname nel guest | dopo l'avvio: `incus exec NUOVA -- sh -c 'echo NUOVA > /etc/hostname; hostname NUOVA'`, poi `incus restart NUOVA` |

### Copy (clone)

```bash
incus copy NOME CLONE                       # anche da accesa; o NOME/SNAP
incus config device set CLONE eth0 ipv4.address=ALTRO_IP
incus config device set CLONE ssh listen=tcp:0.0.0.0:ALTRA_PORTA
incus start CLONE
```

`copy` genera da solo un MAC nuovo. IP fisso e porta pubblicata invece restano quelli dell'originale e vanno cambiati, altrimenti l'avvio fallisce. L'hostname si cambia come sopra.

### Publish (istanza → immagine)

```bash
incus snapshot create NOME base
incus publish NOME/base --alias mia-base
incus launch mia-base nuova -c limits.memory=2GiB      # solo il filesystem: limiti, device e IP vanno ridati
```

Si usa come base per altre istanze con `incus launch` (misurato: l'istanza nuova parte, senza IP fisso né limiti). Con gli script (`INSTANCE_IMAGE=mia-base`) il provisioning rigirerebbe su un guest già configurato: non provato, meglio evitarlo.

### Backup a freddo dell'ambiente

Salva tutto (`INCUS_DATA` + `ALPINE_HOME`), con permessi e proprietari numerici: i file delle istanze non privilegiate appartengono a uid 1000000+. Va fatto a container fermo, perché il database e le istanze non devono cambiare durante la copia.

```bash
cd /percorso/del/compose
docker compose -f docker-compose.incus.yml stop          # ferma le istanze in ordine (15 s nel test)
sudo tar --numeric-owner --xattrs --acls -czpf /backup/incus-env-$(date +%F).tar.gz \
  -C ./data/incus data alpine-home                         # i percorsi di INCUS_DATA e ALPINE_HOME
docker compose -f docker-compose.incus.yml start
```

Ripristino (stessa macchina o un'altra, con la stessa immagine):

```bash
sudo mkdir -p /srv/incus && sudo tar --numeric-owner --xattrs --acls -xzpf /backup/incus-env-AAAA-MM-GG.tar.gz -C /srv/incus
INCUS_DATA=/srv/incus/data ALPINE_HOME=/srv/incus/alpine-home docker compose -f docker-compose.incus.yml up -d
```

Misurato: istanza con IP fisso, snapshot, file e container Docker `unless-stopped` di nuovo `RUNNING` al primo avvio sulle directory ripristinate, senza altri passi.

Se `tar` non è disponibile come root sull'host, si fa con l'immagine stessa:

```bash
docker run --rm -u 0 --entrypoint tar -v /percorso/data/incus:/src:ro -v /backup:/dst \
  ghcr.io/manprint/dind-official-full-incus:TAG --numeric-owner --xattrs --acls -czpf /dst/incus-env.tar.gz -C /src data alpine-home
```

### Backup automatico (cron sull'host)

```bash
# /etc/cron.d/incus-backup — ogni notte alle 3, tiene 7 giorni
0 3 * * * root docker exec -u alpine incus-env sh -c 'mkdir -p ~/backups && incus export web ~/backups/web-$(date +\%F).tar.gz --instance-only' && find /percorso/alpine-home/backups -name 'web-*.tar.gz' -mtime +7 -delete
```

`~/backups` nel container è `ALPINE_HOME/backups` sull'host: da lì si copia altrove (rclone, rsync).

## 9. Server remoto

```bash
# sul server Incus:     incus config trust add qui      → stampa un token
incus remote add lab TOKEN                               # qui
INCUS_REMOTE=lab ./create_incus_debian13.sh
```

Gli script girano ovunque ci sia il client `incus`. I comandi `incus` di questa guida accettano `lab:NOME` al posto di `NOME`.

## 10. Problemi frequenti

| Messaggio / sintomo | Causa | Soluzione |
|---|---|---|
| `instance NOME already exists (INSTANCE_RECREATE=true replaces it)` | nome già usato | un altro `INSTANCE_NAME`, oppure `INSTANCE_RECREATE=true` (cancella l'esistente) |
| `cannot reach the incus daemon` | daemon non pronto o remote sbagliato | `incus info`; `docker logs incus-env` |
| `has no working network/DNS after 90s` | l'istanza non risolve il mirror | rete del bridge (`incus network show incusbr0`), DNS dell'host; `WAIT_NETWORK_SECONDS` più alto |
| `INSTANCE_SWAP '…' is not a size` | formato | `512MiB`, `1GiB`, `2G`, `0` |
| `user … exists with another uid` / `uid … belongs to …` | l'immagine ha già quell'utente o quell'uid | `USER_UID` o `USER_NAME` diversi |
| `free` mostra la RAM dell'host | Alpine con istanza privilegiata | v. [Gestione RAM e swap](README_INCUS.md#gestione-ram-e-swap) |
| `MAC address … already defined on another NIC` | istanza importata o copiata accanto all'originale | §8, tabella dei conflitti |
| `Renaming of running instance not allowed` | rename da accesa | `incus stop` prima |
| `cannot set 'lxc.cgroup2.memory.swap.max ' … unknown key` | sintassi a spazio con `raw.lxc` | `raw.lxc="…"` |
| porta pubblicata irraggiungibile dall'host | manca in `ports:` del compose | aggiungila e `docker compose up -d` |
| `Permission denied` in una cartella condivisa | uid non mappati | `shift=true` sul device `disk` |
