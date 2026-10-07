# Incus-in-Docker

Variante dell'immagine che al posto di Docker esegue **Incus 7.5.1** (container di sistema, niente VM) dentro un container Docker: `Dockerfile.incus`, `entrypoint.incus.sh`, `docker-compose.incus.yml`, `tests/smoke.incus.sh`, `tests/templates.sh`. Rilasciata dalla stessa pipeline delle altre varianti.

- Daemon `incusd` compilato dai sorgenti (7.5.1; Alpine 3.24 pacchettizza solo la 7.0.1 LTS), client `incus`, `fuidshift`.
- **Client web ufficiale** (`incus-ui-canonical`), servito dal daemon su `https://HOST:8443/ui/` e, **senza nessun certificato nel browser**, su `http://HOST:8080/` tramite un proxy interno.
- **API esposta** su 8443 (TLS, solo certificati client fidati): usabile da OpenTofu/Terraform.
- Preseed al primo avvio: pool di storage `default`, bridge `incusbr0`, profilo `default`.
- Stessa base della variante minimal: utente `alpine` + sudo, rclone, fuse, dotfile con prompt `alpine@host(env)(branch)`, `DIND_ENVIRONMENT_NAME`.
- Nessun Docker dentro l'immagine (Docker si installa *dentro* le istanze, vedi sotto).
- **Template per creare istanze** (Alpine 3.24, Debian 13, Ubuntu 24.04 e 26.04, Fedora 44) già pronte per lo sviluppo (utente, ssh, Docker, rclone/fuse, locale e tastiera italiani) in `/opt/incus-template/`: script bash e, in `terraform/`, lo stesso come template OpenTofu/Terraform. Vedi la sezione dedicata.
- **OpenTofu 1.13.1** (`tofu`, con il completamento bash) e il provider `lxc/incus` 1.2.0 già installato: `tofu init` funziona offline.

## Avvio

```bash
docker build -f Dockerfile.incus -t ghcr.io/manprint/dind-official-full-incus:latest .   # oppure: just build-incus
docker compose -f docker-compose.incus.yml up -d
docker compose -f docker-compose.incus.yml exec incus bash

incus launch images:debian/12 web -c limits.memory=512MiB -c limits.cpu=2
incus list
```

L'immagine è costruita e pubblicata dal workflow di release (tag `vX.Y.Z`) come `ghcr.io/<repo>-incus` (multi-arch amd64/arm64, stessi tag delle altre varianti); `docker-compose.incus.yml` è allegato alla release con l'immagine fissata alla versione. In locale: `just build-incus`.

```bash
curl -fsSL https://github.com/manprint/dind-official-full/releases/latest/download/docker-compose.incus.yml -o docker-compose.incus.yml
docker compose -f docker-compose.incus.yml up -d
```

## Cosa serve al container esterno (compose)

Non è `privileged: true`: bastano questi permessi, tutti già nel compose.

| Impostazione | Perché |
|---|---|
| `cap_add: [ALL]` | Incus monta, crea namespace, `mknod`, `setns`, cgroup, rete (bridge, veth, nftables). Il set completo è anche il **tetto** delle capability che le istanze possono avere (vedi sotto). |
| `security_opt: apparmor=unconfined` | Incus applica ai container i propri profili; quello esterno gli sta solo in mezzo. |
| `security_opt: seccomp=unconfined` | Il filtro di Docker blocca syscall che LXC usa (`mount`, `unshare`, `keyctl`…). |
| `security_opt: systempaths=unconfined` | `/proc` e `/sys` senza i path mascherati/read-only di Docker. |
| `cgroup: private` | cgroup namespace proprio: sotto la radice del container nascono i cgroup delle istanze. Serve cgroup v2 sull'host. |
| `devices: /dev/fuse` | lxcfs (vista `/proc/meminfo`, `cpuinfo`… coerente coi limiti) è un filesystem FUSE. |
| `devices: /dev/loop-control` + `device_cgroup_rules: b 7:*` | pool btrfs/lvm su file (loop). L'entrypoint crea a ogni avvio i nodi `loopN` per tutti i loop device dell'host più 32, con il minor giusto anche se il modulo `loop` ha `max_part`. |
| `devices: /dev/net/tun` + regola `c 10:200` | istanze con VPN (TUN). |
| `device_cgroup_rules: c 10:236, c 10:237` | device-mapper e loop-control per LVM. |
| `restart: unless-stopped`, `stop_grace_period: 120s` | ripartenza dopo crash/reboot dell'host; il tempo per fermare le istanze (in parallelo, v. *Stabilità*). |

Anche `privileged: true` funziona, ma non serve.

## Variabili

| Variabile | Default | Effetto |
|---|---|---|
| `INCUS_TAG` | `latest` | tag dell'immagine |
| `INCUS_NAME` | `incus-env` | nome del container |
| `INCUS_API_BIND` / `INCUS_API_PORT` | `127.0.0.1` / `8443` | indirizzo/porta host dell'API. L'API Incus equivale a root sull'host delle istanze: loopback di default, `0.0.0.0` solo con firewall/VPN |
| `INCUS_IPV4`, `INCUS_NET_SUBNET`, `INCUS_NET_GATEWAY` | `10.10.170.1`, `10.10.170.0/24`, `10.10.170.254` | rete Docker dedicata del container |
| `INCUS_DATA` / `ALPINE_HOME` | `./data/incus/data` / `./data/incus/alpine-home` | **bind mount** su `/var/lib/incus` (database, immagini, istanze, pool `dir`) e `/home/alpine`. Docker crea i path mancanti come root. Ogni istanza affiancata ne vuole di propri |
| `DIND_ENVIRONMENT_NAME` | — | nome nel prompt |
| `INCUS_ENV_STORAGE_DRIVER` | `dir` | driver del pool `default`, **solo al primo avvio** (`dir`, `btrfs`, `lvm`) |
| `INCUS_ENV_STORAGE_SIZE` / `INCUS_ENV_STORAGE_SOURCE` | — | `size` (pool su file loop) / `source` (device o path), solo primo avvio |
| `INCUS_ENV_BRIDGE_ADDRESS` | auto | CIDR IPv4 di `incusbr0`, es. `10.10.200.0/24` (un indirizzo di rete diventa il suo `.1`). Applicata **a ogni avvio**: cambiandola il bridge si sposta |
| `INCUS_UI_BIND` / `INCUS_UI_PORT` | `127.0.0.1` / `8080` | indirizzo/porta host del proxy della web UI. Chi lo raggiunge è amministratore di Incus: loopback di default, `0.0.0.0` solo con `INCUS_ENV_UI_PASSWORD` |
| `INCUS_ENV_UI_PROXY` | `on` | `off` spegne il proxy (resta la UI su 8443 con certificato nel browser) |
| `INCUS_ENV_UI_USER` / `INCUS_ENV_UI_PASSWORD` | `admin` / — | con la password il proxy chiede HTTP basic auth |
| `INCUS_ENV_HTTPS_ADDRESS` | `:8443` | `core.https_address`; `none` spegne API e UI. A ogni avvio |
| `INCUS_ENV_TRUST_CERT_FILE` / `_NAME` | — | certificato client (PEM, leggibile nel container) da fidare a ogni avvio, idempotente |
| `INCUS_ENV_SHUTDOWN_TIMEOUT` | `100` | secondi concessi allo stop di Incus (istanze, poi daemon): lo stop intero dura al massimo questo + 10 s. Un valore non numerico o 0 diventa 100, con un warning |
| `INCUS_STOP_GRACE_PERIOD` | `120s` | `stop_grace_period` del container: oltre, Docker uccide tutto. Tienila almeno 10 s sopra `INCUS_ENV_SHUTDOWN_TIMEOUT` |

Il preseed gira una volta (marcatore `/var/lib/incus/.incus-env-initialized`): quello che l'utente cambia dopo non viene rimesso a posto.

## API, web UI, OpenTofu/Terraform

Il client (browser o provider) deve presentare un **certificato TLS client fidato**. Due strade:

```bash
# 1. token monouso
docker exec incus-env incus config trust add tofu          # stampa il token
# 2. certificato già noto, fidato a ogni avvio
INCUS_ENV_TRUST_CERT_FILE=/home/alpine/tofu.crt docker compose -f docker-compose.incus.yml up -d
```

- **UI, senza passaggi**: apri `http://localhost:8080/` (porta `INCUS_UI_PORT`). Dentro il container nginx ascolta su 8080 e parla con l'API su 8443 presentando un certificato client che l'entrypoint genera una volta (`/home/alpine/.config/incus-ui/client.{crt,key}`, EC P-256, 10 anni) e fida da solo (nome `incus-ui`, riaggiunto a ogni avvio se manca). Il browser non importa nulla e la pagina *Setup Incus UI* non compare. WebSocket (console, eventi) e upload di immagini passano dal proxy.
- **UI su 8443**: `https://HOST:8443/ui/` richiede nel browser un certificato fidato (pagina di login: *Generate* + `incus config trust add-certificate`, oppure token). Serve solo con `INCUS_ENV_UI_PROXY=off` o per un accesso diretto.
- **Sicurezza del proxy**: l'accesso a 8080 vale come certificato fidato, cioè root sull'host delle istanze. Per questo è pubblicato su loopback; esponendolo in LAN imposta `INCUS_ENV_UI_PASSWORD` (basic auth, hash `apr1` in `/tmp/incus-ui/htpasswd`) e metti TLS davanti (reverse proxy), perché la basic auth su HTTP passa in chiaro.
- **OpenTofu**: provider `lxc/incus`:

```hcl
terraform {
  required_providers { incus = { source = "lxc/incus" } }
}

variable "token" {
  type      = string
  sensitive = true
}

provider "incus" {
  generate_client_certificates = true
  accept_remote_certificate    = true
  default_remote               = "incus-env"

  remote {
    name    = "incus-env"
    address = "https://127.0.0.1:8443"
    token   = var.token # monouso: dopo il primo apply il certificato generato è fidato
  }
}

resource "incus_instance" "web" {
  name  = "web"
  image = "images:debian/12"
  config = {
    "limits.memory"  = "512MiB"
    "boot.autostart" = true
  }
}
```

- **OpenTofu dentro il container**: `tofu` (OpenTofu 1.13.1) è nell'immagine. Il provider `lxc/incus` 1.2.0 sta nel mirror locale implicito `/usr/share/terraform/plugins`, quindi `tofu init` lo collega senza scaricare nulla (provato con `--network none`). Lì il provider usa la configurazione del client `incus` e il socket locale, come gli script, senza token né certificati. Per istanze già configurate c'è il template `/opt/incus-template/terraform` (v. *Template per creare istanze*).

## Come lanciare i container, e con quali capability

Si lavora con il client `incus` dentro il container (`docker exec -it incus-env incus …`), dalla UI o dall'API. Le immagini vengono da `images:` (images.linuxcontainers.org, serve Internet) o da immagini locali (`incus image import`).

### Lancio base

```bash
incus launch images:alpine/edge a1                      # container di sistema, non privilegiato
incus launch images:debian/12 d1 -c boot.autostart=true # riparte con Incus
incus init images:ubuntu/24.04 u1                        # crea senza avviare
incus start u1
incus exec a1 -- sh                                      # shell
incus stop a1 ; incus delete a1
```

Rete: ogni istanza prende un indirizzo DHCP su `incusbr0` con NAT verso l'esterno (profilo `default`). Porte verso l'esterno col device `proxy`:

```bash
incus config device add d1 web proxy listen=tcp:0.0.0.0:8080 connect=tcp:127.0.0.1:80
```

La porta 8080 vive nel container Docker: va pubblicata anche lì (`ports:` nel compose) per raggiungerla dall'host.

### Risorse (verificate)

| Chiave | Effetto |
|---|---|
| `limits.memory=64MiB` | `memory.max` nel cgroup; l'OOM killer interviene (`dd` oltre il limite: *Killed*); `/proc/meminfo` via lxcfs mostra 64 MiB |
| `limits.cpu=1` | pinning su 1 core (`nproc`=1); `cpu.max` resta `max` |
| `limits.cpu.allowance=20ms/100ms` | quota CFS dura (`cpu.max=20000 100000`, `nr_throttled` cresce). La forma `25%` è invece un peso (`cpu.weight`), non un tetto |
| `limits.processes`, `limits.disk.priority`, `limits.network.*` | gestiti da Incus; `limits.*` su disco richiedono un pool btrfs/lvm |

Funziona solo grazie ai controller cgroup abilitati dall'entrypoint (vedi *Note tecniche*).

### Capability: i tre livelli

Le capability di un'istanza sono sempre un sottoinsieme di quelle del container Docker esterno: `cap_add: ALL` (bounding set `0x1ffffffffff`, tutte e 41) è il tetto.

| Modalità | Come | Capability (misurate) |
|---|---|---|
| **Non privilegiata** (default) | niente da fare | `CapEff=0x1ffffffffff`: **tutte**, ma dentro un user namespace (uid 0 ↔ 1000000). `mount` di tmpfs, `ip link add`, `chown` ecc. funzionano; ciò che tocca l'host no: `date -s` → *Operation not permitted*, niente `sys_module`, nessun accesso ai device dell'host |
| **Privilegiata** | `-c security.privileged=true` | uid 0 = uid 0 dell'host del container, `CapEff=0x1fcfdfcffff`: tutte **tranne** `sys_module`, `sys_rawio`, `sys_time`, `mac_override`, `mac_admin` (le toglie LXC). Anche qui `date -s` fallisce. Da usare solo se un carico di lavoro non regge lo user namespace |
| **Ridotta** | `-c raw.lxc="lxc.cap.drop = net_raw sys_time"` oppure `"lxc.cap.keep = chown dac_override fowner setuid setgid kill net_bind_service"` | `drop` tolto `net_raw`+`sys_time` (`ping` → *permission denied*, `CapBnd=0x1fffdffdfff`); `keep` bounding set ristretto a quelle elencate (`0x4eb`; con `net_admin` assente `ip link add` → *Operation not permitted*, `mount` negato) |

### Altre opzioni che cambiano cosa l'istanza può fare

| Opzione | Uso | Verifica |
|---|---|---|
| `security.nesting=true` | Docker/Podman/LXC dentro l'istanza | Docker funziona (sezione sotto) |
| `security.syscalls.intercept.mknod=true` | `mknod` di device sicuri | `mknod /tmp/n c 1 3` OK |
| `security.syscalls.intercept.setxattr`, `.bpf`, `.mount`, `.sched_setscheduler`, `.sysinfo` | syscall emulate dal daemon | `mknod`/`setxattr` provati |
| `security.idmap.isolated=true`, `security.idmap.size` | range uid dedicato per istanza | mappa di default `0 1000000 1000000000` |
| `linux.kernel_modules=…` | carica moduli dell'host | **non provato**: servono i moduli dell'host e `/lib/modules` nel container |
| device `unix-char`/`unix-block` | passa un device al container | `/dev/fuse` e `/dev/net/tun` sono già visibili in ogni istanza se il container esterno li ha (compose); aggiungerli a mano dà *Failed to add mount… già presente* |
| device `disk` | bind mount di un path del container Incus | OK (`source=/etc/hostname path=/mnt/hn`) |
| device `proxy` | porta `listen` → `connect` | OK (socket in ascolto su 8080) |
| `nic` `bridged` (default) | veth su `incusbr0` | OK; `macvlan`/`physical` non sono utili dentro un container Docker |

Le VM (`--vm`) non sono supportate: niente `/dev/kvm` nel container.

### Docker dentro un'istanza

```bash
incus launch images:debian/12 dk -c security.nesting=true -c limits.memory=2GiB -c limits.cpu=2
incus exec dk -- apt-get install -y docker.io
incus exec dk -- docker run --rm -m 100m --cpus 0.5 alpine cat /sys/fs/cgroup/memory.max
```

Provato su Debian 12 (systemd): `docker run`, `--restart unless-stopped`, `-m 100m` → `memory.max=104857600`, `--cpus 0.5` → `cpu.max=50000 100000`, `--privileged` interno con tutte le capability. Su Alpine (OpenRC) Docker parte e gira, ma i limiti di memoria/CPU dei container interni falliscono (`memory.max: no such file`): nel cgroup radice dell'istanza restano processi e i controller non si possono delegare (EBUSY), lo stesso problema risolto sopra per l'esterno ma lato guest. Per Docker con limiti, usa immagini con systemd.

### Storage

| Driver | Esito |
|---|---|
| `dir` | OK (default) |
| `btrfs` (file loop, `size=2GiB`) | OK, radice istanza su `/dev/loop0` |
| `lvm` con thin pool | **non funziona**: il kernel dell'host non ha il target device-mapper thin-pool |
| `lvm` con `lvm.use_thinpool=false` | OK |
| `zfs` | assente (`zpool` non nell'immagine) |

## Template per creare istanze: `/opt/incus-template`

Cinque script, già nell'immagine in `/opt/incus-template/` (proprietà `alpine`, eseguibili) e in `scripts/` nel repository:

| Script | Immagine di default | Utente | Note |
|---|---|---|---|
| `create_incus_alpine.sh` | `images:alpine/3.24` | `alpine` | OpenRC, `apk` |
| `create_incus_debian13.sh` | `images:debian/13` | `debian` | systemd, `apt` |
| `create_incus_ubuntu2404.sh` | `images:ubuntu/24.04` | `ubuntu` | come Debian; toglie il `sudo` senza password che l'immagine dà a `ubuntu` (`/etc/sudoers.d/90-incus`) |
| `create_incus_ubuntu2604.sh` | `images:ubuntu/26.04` | `ubuntu` | come sopra |
| `create_incus_fedora.sh` | `images:fedora/44` (l'ultima sul server di immagini; per un'altra versione `INSTANCE_IMAGE=images:fedora/45`) | `fedora` | systemd, `dnf`, gruppo `wheel`; Docker dal repository ufficiale, altrimenti `moby-engine` |

Fanno tutti le stesse cose con le stesse variabili.

Si copiano dove serve (un container con il client `incus`, un'altra macchina con `INCUS_REMOTE=...`) e si lanciano. Creano l'istanza e la configurano:

| Cosa | Dettaglio |
|---|---|
| utente | uid **1000** (configurabile) con gruppo, home e shell bash; password `password`; gruppo `sudo`/`wheel` (sudo chiede la password, `USER_SUDO_NOPASSWD=true` per toglierla) |
| ora, lingua, tastiera | `Europe/Rome`, locale `it_IT.UTF-8` (`LANG`, `LC_ALL`, `LANGUAGE`), tastiera `it` (`/etc/default/keyboard`, `/etc/vconsole.conf` tranne Alpine) |
| ssh | server installato e attivo, accesso con password, **root disabilitato**; client `ssh`/`scp`/`sftp` |
| Docker | Alpine: pacchetti `docker` + `docker-cli-compose`; Debian/Ubuntu/Fedora: repository ufficiale Docker (`docker-ce` + plugin compose); se fallisce, o con `DOCKER_SOURCE=distro`, i pacchetti della distribuzione (`docker.io` + `docker-compose` su Debian, `docker.io` + `docker-compose-v2` su Ubuntu, `moby-engine` + `docker-compose` su Fedora). L'utente è nel gruppo `docker`, `daemon.json` con rotazione dei log |
| rete | `ip`, `ping`, `dig`, `tcpdump`, `traceroute`, `mtr`, `nmap`, `nc`, `socat`, `iperf3`, `ethtool`, `ss`/`netstat`, `conntrack`, `iptables`, `nft` |
| rclone + fuse | rclone ufficiale (ultima release, checksum verificato), `fuse`/`fuse3`, `user_allow_other` in `/etc/fuse.conf` |
| shell | `bash-completion` (anche per root) e alias **`ll='ls -alFh'` per tutti gli utenti**, shell di login e non (`/etc/profile.d/10-aliases.sh` + `/etc/bash/10-aliases.sh` su Alpine, `/etc/bash.bashrc` su Debian) |
| altro | git, curl, wget, rsync, unzip, jq, htop, lsof, vim, nano |

L'istanza nasce con `security.nesting=true` (serve a Docker), intercettazione di `mknod`/`setxattr`, `limits.memory=2GiB`, `limits.cpu=2`, `boot.autostart=true`.

Esempi:

```bash
/opt/incus-template/create_incus_alpine.sh
INSTANCE_NAME=web INSTANCE_MEMORY=4GiB INSTANCE_IPV4=10.10.200.50 USER_PASSWORD=altra /opt/incus-template/create_incus_debian13.sh
INSTANCE_RECREATE=true INSTALL_DOCKER=false INSTANCE_SSH_PUBLISH_PORT=2222 /opt/incus-template/create_incus_alpine.sh
```

Una password debole come `password` va cambiata (o `SSH_PASSWORD_AUTH=no` con chiavi) prima di esporre l'istanza.

### Lo stesso con OpenTofu: `/opt/incus-template/terraform`

Il template OpenTofu/Terraform crea la stessa istanza con lo stesso provisioning: `guest/<distro>.sh` è lo script di `create_incus_<distro>.sh` byte per byte (`tests/terraform.sh` lo controlla, insieme ai default). Le impostazioni sono le variabili degli script in minuscolo (`distro` sceglie il template) e si danno come `TF_VAR_*`, in `terraform.tfvars` o con `-var`. Guida completa: [scripts/terraform/README.md](scripts/terraform/README.md), anche nell'immagine.

```bash
cp -r /opt/incus-template/terraform ~/web && cd ~/web    # lo stato va sotto la home, non in /opt
tofu init
TF_VAR_distro=alpine TF_VAR_instance_name=web TF_VAR_instance_memory=4GiB tofu apply
tofu output                                               # name, ipv4, ipv6, user, ssh
```

Rispetto agli script:
- rilanciare `tofu apply` senza cambiare nulla non fa nulla (lo script invece rifiuta un'istanza che esiste già). Le impostazioni dell'istanza (limiti, swap, device) cambiano **sul posto**, quelle del guest (utente, lingua, pacchetti…) **ricreano** l'istanza, e il piano lo dice;
- un provisioning fallito lascia l'istanza *tainted* con l'output dello script nell'errore;
- `tofu destroy` la cancella.

### Variabili (le stesse nei cinque script salvo dove indicato)

Tutte con un default in testata, sovrascrivibili dall'ambiente.

| Variabile | Default | Effetto |
|---|---|---|
| `INCUS_REMOTE` | vuoto | remote `incus` da usare |
| `INSTANCE_NAME` | `alpine-dev`, `debian13-dev`, `ubuntu2404-dev`, `ubuntu2604-dev`, `fedora-dev` | nome (anche hostname) |
| `INSTANCE_IMAGE` | v. tabella sopra | immagine |
| `INSTANCE_PROFILES` | `default` | profili, separati da spazio |
| `INSTANCE_STORAGE_POOL`, `INSTANCE_NETWORK` | vuoti | pool/rete se diversi dal profilo |
| `INSTANCE_IPV4` | vuoto | indirizzo fisso sul bridge gestito |
| `INSTANCE_MEMORY`, `INSTANCE_CPU` | `2GiB`, `2` | `limits.memory`, `limits.cpu` (vuoto = nessun limite) |
| `INSTANCE_SWAP` | vuoto | swap usabile dall'istanza: `512MiB`, `1GiB`, `2G`…; `0`/`off` = nessuna; vuoto = default di Incus (**nessuna**, anche con `limits.memory.swap=true`). Vedi *Memoria e swap* |
| `INSTANCE_DISK_SIZE` | vuoto | dimensione disco root (pool btrfs/lvm) |
| `INSTANCE_NESTING`, `INSTANCE_INTERCEPT`, `INSTANCE_PRIVILEGED`, `INSTANCE_AUTOSTART` | `true`, `true`, `false`, `true` | `security.nesting`, intercept `mknod`/`setxattr`/`sysinfo`, `security.privileged`, `boot.autostart` |
| `INSTANCE_CONFIG` | vuoto | altre chiavi `key=value` separate da spazio |
| `INSTANCE_SSH_PUBLISH_PORT` | vuoto | porta dell'host incus inoltrata alla 22 (device `proxy`) |
| `INSTANCE_RECREATE` | `false` | cancella un'istanza esistente con lo stesso nome (altrimenti errore) |
| `USER_NAME`, `USER_UID` | `alpine`/`debian`/`ubuntu`/`fedora`, `1000` | utente |
| `USER_PASSWORD`, `USER_SHELL` | `password`, `/bin/bash` | |
| `USER_SUDO`, `USER_SUDO_NOPASSWD` | `true`, `false` | |
| `TIMEZONE`, `LOCALE`, `KEYMAP` | `Europe/Rome`, `it_IT.UTF-8`, `it` | su Fedora il langpack segue `LOCALE` (`en_US.UTF-8` → `glibc-langpack-en`) |
| `SSH_PASSWORD_AUTH`, `SSH_PERMIT_ROOT` | `yes`, `no` | |
| `INSTALL_DOCKER`, `INSTALL_NET_TOOLS`, `INSTALL_RCLONE` | `true` | |
| `DOCKER_SOURCE` (non Alpine) | `official` | `official` o `distro` (`docker.io` su Debian/Ubuntu, `moby-engine` su Fedora, con il loro `docker compose`) |
| `DOCKER_LOG_MAX_SIZE`, `DOCKER_LOG_MAX_FILE` | `10m`, `5` | |
| `RCLONE_RELEASE` | `current` | o una versione, es. `v1.70.0` (non `RCLONE_VERSION`: rclone la legge come `--version`) |
| `EXTRA_PACKAGES` | vuoto | altri pacchetti apk/apt/dnf |
| `WAIT_NETWORK_SECONDS` | `90` | attesa di rete/DNS prima di installare |

### Memoria, swap e CPU: cosa vedono i tool

`limits.memory` e `limits.cpu` finiscono nel cgroup dell'istanza (`memory.max`, cpuset); lxcfs virtualizza `/proc/meminfo`, `/proc/cpuinfo`, `/proc/swaps`, `/proc/stat`. I tool sono coerenti solo se leggono da lì.

- **Swap.** Incus non ha una *dimensione* di swap per i container: `limits.memory.swap` è un booleano e, misurato su Incus 7.5.1 con `limits.memory=2GiB`, `memory.swap.max` resta **0** sia di default sia con `true` (quindi lxcfs mostra `SwapTotal: 0` e htop `0K/0K`: è corretto, non c'è swap). `INSTANCE_SWAP=1GiB` scrive `raw.lxc: lxc.cgroup2.memory.swap.max = 1073741824` (misurato: cgroup, `/proc/meminfo`, `free`, htop mostrano 1 GiB, e sotto pressione la memoria finisce davvero in swap); `INSTANCE_SWAP=0` imposta `limits.memory.swap=false`. L'host deve avere swap (file o zram). `INSTANCE_CONFIG="raw.lxc=..."` ha la precedenza.
- **`free` e `top` di busybox (Alpine) mostravano 47 GB e 2 GB di swap**, cioè l'host: usano la syscall `sysinfo()`, non `/proc/meminfo`. Gli script impostano `security.syscalls.intercept.sysinfo=true` (parte di `INSTANCE_INTERCEPT`): ora `free` dice 2048 MB e lo swap vero.
- **`top`/`htop` con 0 usati su Alpine con Docker.** lxcfs calcola l'uso dal cgroup del PID 1 e toglie solo il suffisso `init.scope`. Il servizio OpenRC `cgroup-delegate` spostava i processi in `/init`: lxcfs leggeva un cgroup vuoto e `MemFree` era uguale a `MemTotal`, mentre il limite (2 GiB) era giusto. Ora li sposta in `init.scope`.
- **Verifica** (`tests/templates.sh`, per ogni template, al primo avvio e dopo un riavvio): `memory.max` 2 GiB, `MemTotal` 2097152 kB, `nproc` e `/proc/cpuinfo` = 2 CPU, `free` totale 2048; un processo che alloca 300 MiB li fa comparire come *usati* in `free`, `/proc/meminfo`, `memory.current` e (Alpine) `busybox top`; con `INSTANCE_SWAP=1GiB` cgroup, `/proc/meminfo` e `free` dicono 1 GiB e 2,4 GiB di tmpfs in un'istanza da 2 GiB entrano solo usando la swap.

### Docker annidato su Alpine

OpenRC lascia tutti i processi nel cgroup radice dell'istanza, che quindi non può delegare i controller ai cgroup di Docker (`docker run -m` falliva con *memory.max: no such file*). Lo script Alpine installa il servizio OpenRC `cgroup-delegate` (prima di `docker`, al boot) che sposta i processi in `/sys/fs/cgroup/init.scope` (il nome conta: lxcfs toglie quel suffisso quando legge l'uso dell'istanza; con `init` `free`/`top`/`htop` mostravano 0 usati) e abilita i controller: con questo `-m 100m` e `--cpus 0.5` funzionano, anche dopo un riavvio dell'istanza. Su Debian lo fa systemd.

### Verifica eseguita

`tests/templates.sh IMAGE [alpine|debian13|ubuntu2404|ubuntu2604|fedora ...]` (`just templates-incus TAG [template...]`) avvia l'immagine su bind mount nuovi, lancia ogni script con i suoi default (più `INSTANCE_SWAP=1GiB`), verifica, riavvia l'istanza e ripete i controlli. Serve internet (immagini delle istanze, pacchetti, repository Docker, rclone), quindi **non** fa parte della pipeline di release, il cui smoke test non usa registry. `SCRIPTS_DIR=scripts` prova gli script del working tree (compreso `terraform/`) invece di quelli nell'immagine; `TPL_ENV="DOCKER_SOURCE=distro"` aggiunge impostazioni a ogni esecuzione degli script. `MODE=tofu` (`just templates-incus-tofu`) crea le istanze con il template OpenTofu invece che con gli script (impostazioni come `TF_VAR_*`) e ripete tutti i controlli.

| Verifica (tutte OK su ciascun template) | Alpine 3.24 | Debian 13 | Ubuntu 24.04 | Ubuntu 26.04 | Fedora 44 |
|---|---|---|---|---|---|
| creazione e provisioning da zero | 19–25 s | 26–29 s | 37–43 s | 37–40 s | 43–160 s (dnf) |
| la riga finale dello script riporta l'IP dell'istanza | ✓ | ✓ | ✓ | ✓ | ✓ |
| utente uid 1000, home, bash, gruppi (`wheel`/`sudo`, `docker`) | ✓ | ✓ | ✓ | ✓ | ✓ |
| `Europe/Rome`, `CET/CEST`, `LANG`/`LC_ALL=it_IT.UTF-8` in login shell e in una sessione ssh interattiva, locale generato, tastiera `it` | ✓ | ✓ | ✓ | ✓ | ✓ |
| ssh: login con password; password errata e `root` rifiutati | ✓ | ✓ | ✓ | ✓ | ✓ |
| `sudo` chiede la password e funziona con quella | ✓ | ✓ | ✓ (tolto `90-incus`) | ✓ | ✓ |
| strumenti di rete, git/curl/wget/rsync/jq/htop/vim/nano, client ssh, rclone, `user_allow_other`, `fusermount` | ✓ | ✓ | ✓ | ✓ | ✓ |
| alias `ll` e bash-completion per utente e root, shell di login e non | ✓ | ✓ | ✓ | ✓ | ✓ |
| memoria 2 GiB e 2 CPU coerenti in cgroup, `/proc/meminfo`, `free` (e `top` busybox); 300 MiB allocati risultano usati | ✓ | ✓ | ✓ | ✓ | ✓ |
| `INSTANCE_SWAP=1GiB`: cgroup, `/proc/meminfo`, `free` a 1 GiB; 2,4 GiB di tmpfs entrano usando la swap | ✓ | ✓ | ✓ | ✓ | ✓ |
| `INSTANCE_SWAP=lots` rifiutato prima di lanciare nulla | ✓ | ✓ | ✓ | ✓ | ✓ |
| ssh e Docker attivi, `docker run -m 100m --cpus 0.5` → `104857600` / `50000 100000` | ✓ | ✓ | ✓ | ✓ | ✓ |
| stessi controlli dopo il riavvio dell'istanza | ✓ | ✓ | ✓ | ✓ | ✓ |
| seconda esecuzione senza `INSTANCE_RECREATE`: errore | ✓ | ✓ | ✓ | ✓ | ✓ |
| tutta la tabella con `DOCKER_SOURCE=distro` (pacchetti Docker della distribuzione) | — | ✓ | ✓ | ✓ | — |
| tutta la tabella con il **template OpenTofu** (`MODE=tofu`): creazione e provisioning | 19 s | 29 s | 43 s | 40 s | 56 s |
| OpenTofu: output (`ipv4`, `user`, `ssh`, `user_password`), piano vuoto dopo provisioning e riavvio, `limits.memory` a 3 GiB **sul posto** (istanza non ricreata), cambio di `locale` pianificato come **sostituzione**, secondo stato con lo stesso nome rifiutato senza toccare l'istanza, `destroy` | ✓ | ✓ | ✓ | ✓ | ✓ |

Non ripetuti per ogni script (stesso codice): `INSTANCE_IPV4`, `INSTANCE_SSH_PUBLISH_PORT`, utente/uid/password/timezone diversi, `EXTRA_PACKAGES`, `USER_SUDO_NOPASSWD`, `INSTALL_*=false`, memoria/CPU vuote, `INSTANCE_SWAP=0` e `off`. La conversione di `INSTANCE_SWAP` (`1GiB`, `512MiB`, `0`) è provata a mano su Alpine. `DOCKER_SOURCE=distro` non riguarda Alpine (usa sempre i suoi pacchetti) e su Fedora installa `moby-engine` + `docker-compose`, che contiene il plugin `docker compose` (verificato sul pacchetto, non con il test completo).

### Immagini `jrei` (systemd/OpenRC) sul Docker delle istanze

Le immagini di <https://hub.docker.com/u/jrei> eseguono un init vero (systemd o OpenRC) dentro un container Docker. Provate con `JREI=1 tests/templates.sh IMAGE` sul demone Docker di **ognuno dei cinque template**, nel modo documentato dalle immagini:

```bash
docker run -d --name x \
  --tmpfs /tmp --tmpfs /run --tmpfs /run/lock \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw --cgroupns=host \
  --stop-signal SIGRTMIN+3 \          # solo systemd; OpenRC (busybox init) usa il SIGTERM di default
  jrei/systemd-debian:13                 # con o senza --privileged
```

Per ogni immagine e per ogni modo (senza e con `--privileged`) il test attende che systemd sia `running`/`degraded` (OpenRC: runlevel `default`), verifica PID 1 = systemd, esegue una unit oneshot, controlla `systemd-journald`, ferma con `docker stop`, riparte e riattende. Risultato, **identico su tutti e cinque i template** (18 esecuzioni per template, 90 in tutto: 80 OK, 10 attesi come falliti):

| Immagine | Senza `--privileged` | Con `--privileged` |
|---|---|---|
| `systemd-debian:12`, `:13` | OK, stop 0–1 s, exit 0 | OK, stop ≤1 s, exit 130 |
| `systemd-ubuntu:22.04`, `:24.04`, `:26.04` | OK, stop 0–1 s, exit 0 | OK, exit 130 |
| `systemd-fedora:latest` (44) | OK | OK, exit 130 |
| `systemd-centos:8` | parte e gira; `docker stop` ignora `SIGRTMIN+3` e arriva a SIGKILL dopo il timeout (exit 137) | OK, exit 130 |
| `systemd-centos:7` | **non parte** | **non parte** |
| `openrc-alpine:latest` | OK, stop 3–4 s, exit 0 | OK, stop 2 s, exit 129 |

- **Non sono difetti di Incus**: gli stessi comportamenti si ottengono su un host Docker normale (provato): exit 130/129 con `--privileged` (systemd su `SIGRTMIN+3`, busybox init su `SIGTERM`), CentOS 8 che ignora il segnale senza `--privileged`, CentOS 7 (systemd 219) che non gira su cgroup v2 (`Failed to get D-Bus connection`).
- **`--cgroupns=private` non va con queste immagini**, né qui né su un host normale: dichiarano `VOLUME /sys/fs/cgroup`, quindi senza il bind esplicito Docker vi monta un volume vuoto e systemd esce subito (`Failed to set RLIMIT_CORE`, exit 255). Il bind con `--cgroupns=host` è il modo che funziona.
- `Failed to set RLIMIT_CORE: Operation not permitted` compare in log anche quando tutto funziona.
- **Fedora**: l'immagine non ha un broker D-Bus, quindi `systemd-run` non funziona (`Failed to connect to system scope bus`); il test usa una unit oneshot.
- Le immagini si scaricano una volta dall'host del test e si caricano in ogni istanza (`docker save | docker load`): il limite di pull anonimo di Docker Hub non regge 5 template × 10 immagini.

## Stabilità: cosa fa l'entrypoint

tini è PID 1 (reaper, inoltra SIGTERM); l'entrypoint ne è l'unico figlio. Il daemon parte così:

1. pulizia dello stato stantio **del container** (`/run/incus`, `/run/lxc`, il pidfile `/run/incus-env.pid`, mount lxcfs orfano);
2. rientro come root con `flock` sul data-root (`/var/lib/incus/.incus-env.lock`, fd ereditato da `incusd`): due container sullo stesso volume → il secondo esce con **75**;
3. **dopo** il lock, pulizia dei file stantii nel volume (`unix.socket`, `guestapi/sock`, `networks/*/dnsmasq.pid`, `forkdns.*`): senza pulizia, un `dnsmasq.pid` che dopo un hard stop nomina un pid *vivo* di un altro processo fa fallire il bridge;
4. controllo del certificato del server: `incusd` genera `server.crt`/`server.key` al primo avvio e da lì in poi li carica senza rigenerarli, quindi una coppia vuota o troncata (corrente mancata durante quel primo avvio) faceva fallire ogni avvio successivo, un loop di restart. Ora una coppia che non si carica viene messa da parte (`*.incus-env-corrupt.<data>`) e `incusd` ne crea una nuova; i client remoti che si fidavano della vecchia (`incus remote add`, OpenTofu) devono riaccettarla;
5. cgroup: remount rw di `/sys` e `/sys/fs/cgroup`, **tutti i processi in `/sys/fs/cgroup/init.scope`** e abilitazione di tutti i controller alla radice;
6. nodi loop (tutti quelli dell'host più 32), `/etc/subuid`/`subgid` (`root:1000000:1000000000`), `mount --make-rshared /`, lxcfs. lxcfs parte staccato, così quando muore lo raccoglie tini (da figlio di `incusd` restava zombie e sembrava vivo), e con `oom_score_adj=-1000`: l'OOM killer sceglie un processo di un'istanza, non lui;
7. `incusd --group incus-admin`, con il pid in `/run/incus-env.pid`; l'entrypoint attende che l'API risponda *e* che sia il proprio `incusd`, poi applica preseed/configurazione.

Poi, ogni 5 s, la supervisione:

- se all'avvio l'API non aveva risposto in tempo, applica la configurazione (preseed, indirizzi, certificati, proxy della UI) appena risponde: prima veniva saltata fino al riavvio successivo. Un errore nella configurazione o nel proxy non ferma più il container;
- se lxcfs muore lo riavvia; se muore il proxy della UI lo riavvia, uccidendo prima il suo process group (il worker orfano tiene la porta 8080), mai un `nginx` qualsiasi: in un'istanza privilegiata i processi dell'uid 1000 sono dello stesso utente `alpine`. Al massimo 5 riavvii ciascuno, poi un warning e basta;
- se `incusd` muore da solo il container esce con il suo stato (o 1): `restart: unless-stopped` lo rialza.

Allo stop (`docker stop`, SIGTERM) c'è **una** richiesta `incus admin shutdown --force --timeout N` (N = `INCUS_ENV_SHUTDOWN_TIMEOUT`): Incus ferma le istanze in parallelo, tante alla volta quante le CPU, ciascuna entro il suo `boot.host_shutdown_timeout` (30 s di default, poi la uccide), e poi il daemon.

- `--force` evita di aspettare le operazioni in corso. Senza, un'operazione che non si può annullare (un export, il download di un'immagine, un `incus stop` lungo) teneva ferme le istanze finché non finiva, fino a `core.shutdown_timeout` (5 minuti), ben oltre la grazia di Docker: misurati 59 s con un export, e con un'operazione più lunga SIGKILL a tutto.
- Se l'API non risponde, l'entrypoint manda **SIGPWR** a `incusd`, che fa lo stesso shutdown completo. Non SIGTERM: per `incusd` è un reload, esce lasciando le istanze accese, che poi morivano con il container (misurati 120 s, exit 137, istanze uccise senza shutdown). Il segnale va al solo daemon, letto dal pidfile: `pidof incusd` trova anche i monitor LXC (`[lxc monitor]` ha lo stesso nome), che girano il segnale all'init dell'istanza.
- Lo stop intero dura al massimo `INCUS_ENV_SHUTDOWN_TIMEOUT` + 10 s, sotto i 120 s di `stop_grace_period`.

### Note tecniche: perché `init.scope`

LXC ricava il cgroup base delle istanze da `/proc/1/cgroup`, toglie `init.scope` dal percorso (come sotto systemd) e scrive `+controller` nel `cgroup.subtree_control` del cgroup base. Un cgroup che contiene processi non può abilitare controller (EBUSY) e in un container tutti i processi partono nell'unico cgroup esistente. Spostarli tutti in `init.scope` e abilitare i controller alla radice è ciò che fa funzionare `limits.memory`, `limits.cpu` & co. Con `/init` l'abilitazione dà EBUSY e `memory.max` non esiste (*Failed to set memory.max*). Poiché `wait_incus` fa partire processi mentre il lato root sposta gli altri, lo spostamento viene ripetuto finché i controller passano (fino a 5 s).

## Matrice di test eseguita

Host: Linux 7.0, cgroup v2, Docker. Immagine con Incus 7.5.1, due istanze (`a1` con `limits.memory=64MiB`, `b1`) salvo dove indicato. «Crash» = `kill -9` del PID 1 del container dall'host, con `restart: unless-stopped` attivo.

| # | Verifica | Esito |
|---|---|---|
| 1 | Primo avvio, preseed (pool, bridge, `core.https_address`), healthcheck | OK |
| 2 | `docker restart` ×2 | OK: healthy in ~15 s, istanze `RUNNING`, `memory.max` intatto |
| 3 | `docker kill` + `docker start` ×2 | OK. Nota: `docker kill` (come `stop`) segna il container come fermato a mano: il restart policy **non** lo rialza, serve `start` |
| 4 | Crash (`kill -9` PID 1) ×11, restart automatico | OK: `RestartCount` incrementato ogni volta, ~11 s, istanze e limiti ripartiti, rete delle istanze OK |
| 5 | `docker compose down` + `up` ×2 (volumi mantenuti) | OK |
| 6 | `docker stop` con 2 istanze | OK: 4 s, exit 0; un solo `incus admin shutdown`; istanze di nuovo `RUNNING` dopo `start` |
| 7 | Doppio `docker stop` | OK: exit 0 |
| 8 | Stato stantio dopo hard stop: `dnsmasq.pid` valido (YAML) che nomina il pid 1, `guestapi/sock` file qualsiasi, `unix.socket` residuo | OK dopo la correzione del punto 3 della pulizia; il test ha trovato **due bug** (v. sotto) |
| 9 | Lock: secondo container sul volume del primo, 3 round | OK: exit 75, messaggio chiaro, il primo non perde socket né istanze |
| 10 | Istanza non avviata (`s1`) dopo restart | resta `STOPPED` (nessuno stato inventato) |
| 11 | `incusd` ucciso con SIGKILL | il container esce ≠ 0 e ripartendo torna sano |
| 12 | Doppio SIGTERM | un solo shutdown graceful, exit 0 |
| 13 | Limiti: `limits.memory` | `memory.max=67108864`, OOM kill di `dd`, lxcfs `MemTotal=65536 kB` |
| 14 | Limiti CPU | `limits.cpu=1` → `nproc`=1; `limits.cpu.allowance=20ms/100ms` → `cpu.max=20000 100000`, `nr_throttled` cresce |
| 15 | Capability: non privilegiata, privilegiata, `cap.drop`, `cap.keep` | v. tabella sopra |
| 16 | Syscall intercept (`mknod`, `setxattr`), device `proxy`, `disk` | OK. `/dev/fuse` e `/dev/net/tun` presenti di default nelle istanze (`tun` solo grazie al device nel compose) |
| 17 | Docker annidato: Debian 12 | OK, limiti dei container interni applicati |
| 18 | Docker annidato: Alpine/OpenRC | Docker gira, limiti interni **no** (limite del guest) |
| 19 | Storage: dir, btrfs, lvm (con/senza thin), zfs | v. tabella sopra |
| 20 | API: `/1.0` non autenticato → `untrusted`; con certificato fidato lista istanze e **crea un'istanza** (POST → 202 → `RUNNING`) | OK |
| 21 | UI: `/ui/` → 200, titolo *Incus UI* | OK |
| 22 | Porta pubblicata solo su `127.0.0.1:8443` | OK (`docker port`) |
| 23 | `INCUS_ENV_BRIDGE_ADDRESS=10.10.200.0/24` al primo avvio; poi `10.10.201.0/24` a istanza attiva | OK: bridge e istanza (nuovo DHCP, rete funzionante) sulla nuova subnet |
| 24 | `INCUS_ENV_HTTPS_ADDRESS=none` | OK: nessun listener 8443 |
| 25 | `INCUS_ENV_TRUST_CERT_FILE` al primo avvio e a ogni riavvio | OK: un solo certificato `tofu` |
| 26 | `INCUS_ENV_STORAGE_DRIVER=btrfs` + `SIZE=3GiB` | OK |
| 27 | Shell interattiva (`docker run -it`): prompt a colori con `(itenv)`, `exit` ferma il daemon pulito, nessun residuo | OK |
| 28 | `tests/smoke.incus.sh` (18 controlli, 3 cicli di kill, su bind mount) | OK in ~30 s |
| 29 | Build da zero (`just build-incus-clean`: `incusd` e UI compilati, checksum del sorgente verificato) + `tests/smoke.incus.sh` sull'immagine così costruita | OK, 18/18; build 1 min 8 s su questo host |
| 32 | Template `create_incus_alpine.sh` / `create_incus_debian13.sh` (v. sezione dedicata): utente, ssh, locale/ora/tastiera, Docker annidato con limiti, rclone/fuse, variabili | OK su entrambi, ~25 s ciascuno |
| 33 | **Proxy web UI** su 8080: primo avvio genera e fida il certificato `incus-ui`; `/ui/` 200 e `/1.0` `auth: trusted` senza nulla nel browser; `/` → 302 `/ui/`; WebSocket `/1.0/events` → 101; ricreazione del container, `kill -9` del PID 1 e `docker stop`: stesso certificato, una sola voce nel trust store, stop 1 s exit 0 | OK |
| 34 | Proxy con `INCUS_ENV_UI_PASSWORD`: senza credenziali o con password errata 401, corretta 200 | OK |
| 35 | Smoke test (`tests/smoke.incus.sh`) con il controllo del proxy | OK, 19/19 |
| 36 | **Ubuntu 24.04, Ubuntu 26.04, Fedora 44**: `create_incus_ubuntu2404.sh`, `create_incus_ubuntu2604.sh`, `create_incus_fedora.sh` con `tests/templates.sh` (tutta la tabella *Verifica eseguita*) | OK; 3 bug trovati e corretti (sotto) |
| 37 | **Memoria e swap**: `INSTANCE_SWAP` (cgroup, lxcfs, `free`, htop; swap usata sotto pressione), `sysinfo` intercettato, `init.scope` su Alpine; `free`/`top`/`htop` coerenti con il limite | OK su tutti e cinque i template, prima e dopo il riavvio |
| 38 | **Immagini jrei** (systemd Debian 12/13, Ubuntu 22.04/24.04/26.04, Fedora, CentOS 7/8, OpenRC Alpine) sul Docker di ogni template, con e senza `--privileged` | OK 80/90; i 10 restanti (CentOS 7, 2 modi × 5 template) sono attesi (systemd 219 su cgroup v2) e uguali su un host normale |
| 31 | Compose con **bind mount** su ext4 (`INCUS_DATA`/`ALPINE_HOME`): primo avvio, `docker restart`, 3 crash, `down`/`up`, istanze Debian (nesting) e Alpine con limiti | OK: stato identico ai named volume, home seminata (dotfile di `alpine`), `memory.max` e rete intatti |
| 30 | **OpenTofu** (provider `lxc/incus`) dal host contro la porta 8443 pubblicata: `apply` con token, istanza `tf1` con `limits.memory` creata e `RUNNING`; dopo un crash del container `plan` senza drift; `destroy` | OK |
| 39 | `docker stop` mentre gira un'operazione che non si può annullare (`incus stop --timeout 300` su un'istanza che ignora SIGPWR) | OK: 6–7 s, exit 0, l'altra istanza fermata in ordine (prima della correzione: lo shutdown aspettava l'operazione, 59 s con un export) |
| 40 | `docker stop` con l'API irraggiungibile per il client (`unix.socket` a `0600`) | OK: SIGPWR, 2–3 s, exit 0, istanza fermata in ordine (prima: SIGTERM, cioè reload, 120 s, exit 137, istanza uccisa) |
| 41 | lxcfs ucciso con `kill -9` | riavviato entro 5 s, di nuovo con `oom_score_adj=-1000`; le istanze accese leggono *Socket not connected* da `/proc/meminfo` finché non si riavviano (v. *Limiti invalicabili*); dopo `incus restart` `MemTotal` torna al limite |
| 42 | Proxy UI: master nginx ucciso con `kill -9` (il worker orfano tiene la porta) | riavviato, 8080 risponde 200; un altro processo `nginx` dello stesso utente resta vivo |
| 43 | `server.key` vuoto (corrente mancata durante il primo avvio) | messo da parte, certificato nuovo, istanza di nuovo `RUNNING` (prima: loop di restart) |
| 44 | `kill -9` del PID 1 del container dall'host con `restart: unless-stopped` (ora nello smoke test) | OK: Incus e istanza tornano su da soli |
| 45 | `INCUS_ENV_SHUTDOWN_TIMEOUT` = `090`, `000`, `0`, `abc`, vuota | `090` → 90 s; gli altri → 100 s con un warning (prima `090`, letto come ottale, era un errore fatale a metà dello stop) |
| 46 | `tests/smoke.incus.sh` con tutti i controlli nuovi | OK, 26/26 |
| 47 | `tests/templates.sh` su tutti e cinque i template con gli script corretti, poi `TPL_ENV=DOCKER_SOURCE=distro` su Debian 13, Ubuntu 24.04 e 26.04 | OK: 80/80 e 48/48 |
| 48 | `tests/terraform.sh` (anche nella pipeline). Controlla che `guest/*.sh` sia identico agli heredoc degli script, che ogni impostazione degli script abbia una variabile con lo stesso default, la tabella delle distro e l'ambiente del provisioning. Poi `fmt`, `validate` e i 53 test unitari (provider simulato), su una copia configurata con `terraform.tfvars`, `*.auto.tfvars` e `TF_VAR_*` lontani dai default. Mutazioni introdotte apposta (default cambiato, heredoc modificato, unità dello swap, `tests/terraform.tfvars` svuotato) | OK, tutte le mutazioni rilevate |
| 49 | `tests/smoke.incus.sh` con OpenTofu: `init` dal mirror dell'immagine; i 53 test nell'immagine; rifiuto in `/opt/incus-template`; istanza da `terraform.tfvars` + `TF_VAR_*` (limiti, swap, `eth0` del profilo con IP fisso) e piano vuoto; memoria cambiata sul posto e swap dal riavvio dell'istanza; provisioning fallito (errore con l'output dello script, istanza *tainted*); secondo stato sullo stesso nome rifiutato; stato ancora coerente dopo stop, kill e crash del container; `destroy` | OK, 34/34 in ~90 s |
| 50 | `MODE=tofu tests/templates.sh` sui cinque template (v. *Verifica eseguita*) | OK, 105/105 in 466 s |
| 51 | `tofu init` con `--network none` (provider dal mirror, 53 test); una versione del provider che il mirror non ha → *no available releases match*; con `~/.tofurc` `direct {}` viene scaricata dal registry, firmata | OK |
| 52 | HashiCorp Terraform 1.16.5 sul template (`TOFU=terraform tests/terraform.sh`): `init` da `registry.terraform.io` (stessa chiave di firma), `validate`, `fmt`, 53 test anche sulla copia configurata | OK |

### Bug trovati dai test (e corretti)

1. **Glob non espanso**: la pulizia dei file stantii usava `as_root rm -f …/networks/*/dnsmasq.pid`; il glob lo espandeva la shell `alpine`, che non può leggere `/var/lib/incus/networks` (`drwx--x--x`), quindi non rimuoveva nulla e il `dnsmasq.pid` con un pid riusato lasciava il bridge in errore (*Failed initializing network*) e le istanze `STOPPED`. Ora la pulizia gira in una shell root.
2. **Il perdente del lock cancellava i socket del vincitore**: la pulizia girava prima del lock, quindi un secondo container sullo stesso volume eliminava `unix.socket` del primo (il client smetteva di rispondere). Ora i file nel volume si puliscono solo a lock acquisito; prima del lock si tocca solo `/run` (strato del container). Il perdente non applica più la configurazione perché `wait_incus` richiede un `incusd` nel proprio namespace PID.
3. **Race sui controller cgroup**: i processi lanciati da `wait_incus` mentre il lato root li spostava lasciavano EBUSY (*controller … not delegated*); ora lo spostamento si ripete.
4. **Mancavano** `/etc/subuid`/`subgid`, il remount rw di `/sys` e la sintassi `incus config set chiave=valore` (la forma con spazio è deprecata).
5. **`free`/`top`/`htop` incoerenti su Alpine** (v. *Memoria, swap e CPU*): busybox leggeva `sysinfo()` (RAM e swap dell'host) e il servizio `cgroup-delegate` spostava i processi in `/init` invece di `init.scope`, per cui lxcfs vedeva 0 usati. Corretti con `security.syscalls.intercept.sysinfo=true` e `init.scope`.
6. **Ubuntu: `sudo` senza password.** L'immagine installa `/etc/sudoers.d/90-incus` con `NOPASSWD` per `ubuntu`: lo script lo toglie (ricompare solo con `USER_SUDO_NOPASSWD=true`).
7. **Ubuntu: `ll` sovrascritto.** Il `~/.bashrc` di Ubuntu definisce `alias ll='ls -alF'` dopo `/etc/bash.bashrc`: gli script lo riscrivono in skel, nella home dell'utente e in quella di root.
8. **Fedora: `LC_ALL` azzerato.** `/etc/profile.d/lang.sh` fa `unset LC_ALL` dopo il nostro file: il file è ora `zz-locale.sh` (e `zz-aliases.sh`, perché `colorls.sh` definisce un suo `ll`).
9. **Stop bloccato da un'operazione in corso.** Senza `--force`, `incus admin shutdown` aspettava le operazioni non annullabili (export, download di immagini, stop lunghi) prima di fermare le istanze, fino a 5 minuti: oltre `stop_grace_period`, quindi SIGKILL a istanze e daemon. Ora `--force` (#39).
10. **API irraggiungibile allo stop → SIGTERM.** Per `incusd` SIGTERM è un reload: usciva lasciando le istanze accese, il container arrivava alla fine della grazia e moriva con exit 137, istanze uccise senza shutdown. Ora SIGPWR, che è lo shutdown completo (#40).
11. **`killall incusd` e `pidof incusd` colpivano anche i monitor LXC**, che si chiamano allo stesso modo e girano il segnale all'init dell'istanza. Ora il segnale va al pid scritto in `/run/incus-env.pid`.
12. **`[alert] could not open error log file` di nginx a ogni avvio**: nginx apre il log compilato al suo interno prima di leggere la configurazione, e `alpine` non può scriverlo. Ora `-e stderr`.
13. **lxcfs morto non veniva rilevato.** Era figlio di `incusd` (lanciato prima dell'`exec`), che non lo raccoglieva: restava zombie e `pidof` lo dava per vivo. Ora parte staccato, la supervisione lo riavvia ed è fuori dalla portata dell'OOM killer (#41).
14. **Proxy UI morto non riavviato**, con il worker orfano che teneva la porta. Ora riavviato uccidendo il suo solo process group (#42).
15. **Certificato del server troncato → loop di restart** (#43).
16. **Nodi loop**: erano 16 fissi con minor = indice. Su un host con più loop device (snap) `losetup` sceglieva un indice senza nodo e falliva, e con `max_part` i minor erano sbagliati.
17. **Configurazione saltata** se l'API non rispondeva entro l'attesa iniziale (fino al riavvio successivo), e un errore nella configurazione o nel proxy poteva terminare l'entrypoint (`set -e`), quindi il container.
18. **`INCUS_ENV_SHUTDOWN_TIMEOUT` documentata ma non passata dal compose** (impostarla in `.env` non aveva effetto), e `090` letto come ottale (#45). Ora è nel compose, insieme a `INCUS_STOP_GRACE_PERIOD`.
19. **Template.** `DOCKER_SOURCE=distro` (che è anche il ripiego quando il repository ufficiale non risponde) non funzionava su Ubuntu 24.04: lì `docker-compose` è la v1 in Python, senza il plugin `docker compose`, e lo script falliva alla fine. Ora gli script Ubuntu installano `docker-compose-v2` (su 26.04 `docker-compose` era già un alias di quel pacchetto). La riga finale riportava più indirizzi se un'altra istanza aveva un nome che inizia allo stesso modo (`incus list web` trova anche `web2`). Su Fedora un `LOCALE` diverso da `it_*` non installava il langpack giusto. `INSTANCE_SWAP=08GiB` veniva letto come ottale, e se `downloads.rclone.org` non rispondeva lo script si fermava senza dire perché.

### Cosa NON è stato provato

- Riavvio del demone Docker dell'host (avrebbe fermato gli altri container della macchina): il percorso è lo stesso del crash (#4), perché dopo il reboot Docker rialza il container con `unless-stopped`. Provato invece il `kill -9` del processo principale, che dall'host equivale a un crash/OOM.
- `docker kill` come *crash*: Docker lo tratta come stop manuale (v. #3).
- Spegnimento reale dell'host o della VM: coperto dai due casi che lo compongono, `docker stop` (shutdown ordinato) e `kill -9` del PID 1 (crash), ma il tempo concesso allo stop lo decide il `TimeoutStopSec` di `docker.service` (v. *Limiti invalicabili*). Un OOM reale di lxcfs non è stato provocato: è verificato `oom_score_adj=-1000`.
- arm64, `privileged: true` come variante di compose, `linux.kernel_modules`, VM, ZFS, pool Ceph.
- `tests/templates.sh` non è nella pipeline di release (serve internet, immagini delle istanze, Docker Hub): si lancia a mano. Lo smoke test (`tests/smoke.incus.sh`) invece sì, su ogni digest prima dei tag.
- Template su arm64 (le immagini jrei in lista sono quasi tutte solo amd64).
- Template OpenTofu: solo con lo stato locale nella copia (niente backend remoti né workspace) e senza `tofu import` di istanze create dagli script. HashiCorp Terraform è provato con `init`, `validate` e i test unitari, non contro un Incus vero.

## Limiti invalicabili

Cose che il container non può risolvere da solo: si gestiscono fuori (host, VM, istanze) oppure si accettano. Valgono anche quelle della variante Docker in [README.md](README.md#limiti-invalicabili), in particolare il `TimeoutStopSec` di `docker.service` allo spegnimento dell'host.

- **Caduta di corrente, spegnimento brutale della VM, kernel panic.** Nessuno shutdown è possibile: istanze e daemon muoiono di colpo. Al riavvio container e istanze (`boot.autostart`) tornano su da soli e lo stato stantio viene ripulito (provato: `kill -9` del PID 1 dall'host, `docker kill` con file stantii piazzati, `incusd` ucciso), ma ciò che non era sul disco è perso: l'integrità dei dati delle istanze dipende dal loro `fsync` e da uno storage che rispetti i flush. Un database di Incus danneggiato (`/var/lib/incus/database`) va recuperato a mano; `incus admin recover` reimporta le istanze che sono ancora nei pool.
- **Budget di tempo allo stop.** `INCUS_STOP_GRACE_PERIOD` (120 s) > `INCUS_ENV_SHUTDOWN_TIMEOUT` (100 s) + 10 s, e `INCUS_ENV_SHUTDOWN_TIMEOUT` ≥ (istanze ÷ CPU, per eccesso) × `boot.host_shutdown_timeout` (30 s). Un'istanza che non reagisce a SIGPWR (un init che non gestisce lo spegnimento) viene uccisa allo scadere del suo `boot.host_shutdown_timeout`; se i conti non tornano, Docker uccide tutto allo scadere della grazia e al riavvio si riparte come dopo un crash. Sopra a tutto c'è il `TimeoutStopSec` di `docker.service` quando si spegne l'host.
- **Se `incusd` muore, muoiono le istanze.** Il container esce e viene riavviato, le istanze vengono uccise senza shutdown e ripartono con `boot.autostart`. Non c'è un equivalente del `live-restore`.
- **Se lxcfs muore, le istanze accese restano senza le sue viste finché non si riavviano.** `/proc/meminfo`, `/proc/cpuinfo`, `/proc/stat`, `/proc/uptime`, `/proc/swaps` ecc. sono bind mount del filesystem FUSE di lxcfs: morto il processo, il kernel chiude la connessione e quei file danno *Socket not connected* (misurato: `free` fallisce). L'entrypoint riavvia lxcfs subito e lo protegge dall'OOM killer, ma un nuovo lxcfs non si può riagganciare alle istanze già accese: va fatto `incus restart NOME` (le istanze avviate dopo vedono il nuovo lxcfs). Il log lo segnala: `lxcfs exited, restarting it`.
- **`docker kill` e `docker stop` sono stop manuali**: `restart: unless-stopped` non rialza il container, nemmeno dopo un reboot, finché non si lancia `docker start` o `docker compose up -d`. Un crash vero (OOM, `kill -9`, caduta di corrente) invece sì.
- **Certificato del server rigenerato** (dopo una coppia corrotta): cambia l'impronta, quindi i client remoti e OpenTofu devono riaccettarlo (`accept_remote_certificate` o `incus remote add` di nuovo).
- **Loop device e device-mapper sono dell'host.** I nodi `loopN` vengono creati all'avvio per i loop esistenti più 32: se l'host ne crea molti altri dopo, quelli oltre non sono usabili fino al riavvio del container. I volumi LVM sono device-mapper dell'host e dopo un crash restano attivi sull'host; un loop device lasciato attaccato (`losetup -a` sull'host) si stacca solo dall'host. Per la resilienza conviene il pool `dir` (default) o `btrfs`.
- **Niente VM** (`/dev/kvm` assente), niente ZFS, LVM thin pool solo se il kernel dell'host ha il target `thin-pool`.
- **Requisiti dell'host**: cgroup v2, `/dev/fuse` (senza, le istanze vedono la memoria e le CPU dell'host), kernel e moduli dell'host (le istanze non ne hanno di propri: `sysctl` e moduli sono quelli dell'host).
- **Capability**: un'istanza non ne ha mai più del container esterno (`cap_add: ALL` è il tetto).
- **Sicurezza**: l'API (8443) e il proxy della UI (8080) equivalgono a root sull'host delle istanze; la basic auth del proxy passa in chiaro su HTTP.
- **Template OpenTofu: la password dell'utente è in chiaro nello stato.** `user_password` arriva al provisioning come variabile d'ambiente del comando `exec` del provider. Quindi finisce in `terraform.tfstate` e in un piano salvato con `-out`; `sensitive` la nasconde solo nell'output di `plan`/`apply`. Tieni privata la copia del template, oppure cambia la password nell'istanza dopo la creazione.
- **Template OpenTofu: l'output del provisioning si vede solo se fallisce.** Il provider non trasmette l'output di `exec` mentre gira: per minuti si vede solo *Still creating...*. Se il provisioning fallisce, l'errore riporta stdout e stderr dello script e l'istanza resta *tainted* per l'ispezione.
