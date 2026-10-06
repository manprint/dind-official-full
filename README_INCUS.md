# Incus-in-Docker

Variante dell'immagine che al posto di Docker esegue **Incus 7.5.1** (container di sistema, niente VM) dentro un container Docker. Branch `incus`, `Dockerfile.incus`, `entrypoint.incus.sh`, `docker-compose.incus.yml`, `tests/smoke.incus.sh`.

- Daemon `incusd` compilato dai sorgenti (7.5.1; Alpine 3.24 pacchettizza solo la 7.0.1 LTS), client `incus`, `fuidshift`.
- **Client web ufficiale** (`incus-ui-canonical`), servito dal daemon su `https://HOST:8443/ui/`.
- **API esposta** su 8443 (TLS, solo certificati client fidati): usabile da OpenTofu/Terraform.
- Preseed al primo avvio: pool di storage `default`, bridge `incusbr0`, profilo `default`.
- Stessa base della variante minimal: utente `alpine` + sudo, rclone, fuse, dotfile con prompt `alpine@host(env)(branch)`, `DIND_ENVIRONMENT_NAME`.
- Nessun Docker dentro l'immagine (Docker si installa *dentro* le istanze, vedi sotto).

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
| `devices: /dev/loop-control` + `device_cgroup_rules: b 7:*` | pool btrfs/lvm su file (loop). L'entrypoint crea i nodi `loop0..15`. |
| `devices: /dev/net/tun` + regola `c 10:200` | istanze con VPN (TUN). |
| `device_cgroup_rules: c 10:236, c 10:237` | device-mapper e loop-control per LVM. |
| `restart: unless-stopped`, `stop_grace_period: 120s` | ripartenza dopo crash/reboot dell'host; il tempo per fermare le istanze una a una. |
| `stdin_open: false`, `tty: false` | percorso daemon (come le altre varianti). `compose run` alloca una TTY propria: shell interattiva. |

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
| `INCUS_ENV_HTTPS_ADDRESS` | `:8443` | `core.https_address`; `none` spegne API e UI. A ogni avvio |
| `INCUS_ENV_TRUST_CERT_FILE` / `_NAME` | — | certificato client (PEM, leggibile nel container) da fidare a ogni avvio, idempotente |
| `INCUS_ENV_SHUTDOWN_TIMEOUT` | `100` | secondi concessi a `incus admin shutdown` (tienila sotto `stop_grace_period`) |

Il preseed gira una volta (marcatore `/var/lib/incus/.incus-env-initialized`): quello che l'utente cambia dopo non viene rimesso a posto.

## API, web UI, OpenTofu/Terraform

Il client (browser o provider) deve presentare un **certificato TLS client fidato**. Due strade:

```bash
# 1. token monouso
docker exec incus-env incus config trust add tofu          # stampa il token
# 2. certificato già noto, fidato a ogni avvio
INCUS_ENV_TRUST_CERT_FILE=/home/alpine/tofu.crt docker compose -f docker-compose.incus.yml up -d
```

- **UI**: apri `https://HOST:8443/ui/`, segui la procedura di certificato/token della pagina di login.
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

## Stabilità: cosa fa l'entrypoint

tini è PID 1 (reaper, inoltra SIGTERM); l'entrypoint ne è l'unico figlio. Il daemon parte così:

1. pulizia dello stato stantio **del container** (`/run/incus`, `/run/lxc`, mount lxcfs orfano);
2. rientro come root con `flock` sul data-root (`/var/lib/incus/.incus-env.lock`, fd ereditato da `incusd`): due container sullo stesso volume → il secondo esce con **75**;
3. **dopo** il lock, pulizia dei file stantii nel volume (`unix.socket`, `guestapi/sock`, `networks/*/dnsmasq.pid`, `forkdns.*`): senza pulizia, un `dnsmasq.pid` che dopo un hard stop nomina un pid *vivo* di un altro processo fa fallire il bridge;
4. cgroup: remount rw di `/sys` e `/sys/fs/cgroup`, **tutti i processi in `/sys/fs/cgroup/init.scope`** e abilitazione di tutti i controller alla radice;
5. nodi loop, `/etc/subuid`/`subgid` (`root:1000000:1000000000`), `mount --make-rshared /`, lxcfs;
6. `incusd --group incus-admin`; l'entrypoint attende che l'API risponda *e* che sia il proprio `incusd`, poi applica preseed/configurazione.

Allo stop (`docker stop`, SIGTERM): **una** richiesta `incus admin shutdown --timeout N` (ferma le istanze, poi il daemon), SIGTERM diretto solo se l'API non risponde. Se `incusd` muore da solo il container esce con il suo stato (o 1): `restart: unless-stopped` lo rialza.

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
| 31 | Compose con **bind mount** su ext4 (`INCUS_DATA`/`ALPINE_HOME`): primo avvio, `docker restart`, 3 crash, `down`/`up`, istanze Debian (nesting) e Alpine con limiti | OK: stato identico ai named volume, home seminata (dotfile di `alpine`), `memory.max` e rete intatti |
| 30 | **OpenTofu** (provider `lxc/incus`) dal host contro la porta 8443 pubblicata: `apply` con token, istanza `tf1` con `limits.memory` creata e `RUNNING`; dopo un crash del container `plan` senza drift; `destroy` | OK |

### Bug trovati dai test (e corretti)

1. **Glob non espanso**: la pulizia dei file stantii usava `as_root rm -f …/networks/*/dnsmasq.pid`; il glob lo espandeva la shell `alpine`, che non può leggere `/var/lib/incus/networks` (`drwx--x--x`), quindi non rimuoveva nulla e il `dnsmasq.pid` con un pid riusato lasciava il bridge in errore (*Failed initializing network*) e le istanze `STOPPED`. Ora la pulizia gira in una shell root.
2. **Il perdente del lock cancellava i socket del vincitore**: la pulizia girava prima del lock, quindi un secondo container sullo stesso volume eliminava `unix.socket` del primo (il client smetteva di rispondere). Ora i file nel volume si puliscono solo a lock acquisito; prima del lock si tocca solo `/run` (strato del container). Il perdente non applica più la configurazione perché `wait_incus` richiede un `incusd` nel proprio namespace PID.
3. **Race sui controller cgroup**: i processi lanciati da `wait_incus` mentre il lato root li spostava lasciavano EBUSY (*controller … not delegated*); ora lo spostamento si ripete.
4. **Mancavano** `/etc/subuid`/`subgid`, il remount rw di `/sys` e la sintassi `incus config set chiave=valore` (la forma con spazio è deprecata).

### Cosa NON è stato provato

- Riavvio del demone Docker dell'host (avrebbe fermato gli altri container della macchina): il percorso è lo stesso del crash (#4), perché dopo il reboot Docker rialza il container con `unless-stopped`. Provato invece il `kill -9` del processo principale, che dall'host equivale a un crash/OOM.
- `docker kill` come *crash*: Docker lo tratta come stop manuale (v. #3).
- arm64, `privileged: true` come variante di compose, `linux.kernel_modules`, VM, ZFS, pool Ceph.
- Pipeline di release: estesa a questa immagine (build amd64/arm64, `tests/smoke.incus.sh` su ogni digest prima dei tag), ma **non ancora eseguita su GitHub**: il test è passato in locale, non sui runner (cgroup v2, `/dev/fuse`, `apparmor` dei runner ubuntu-24.04). Un fallimento dello smoke incus blocca anche i tag delle altre varianti.
