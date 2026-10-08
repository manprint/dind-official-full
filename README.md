# dind-env

`docker:29.8.2-dind` + toolchain di sviluppo. `dockerd` resta root (comportamento DinD); la sessione parte come `alpine` (uid/gid 1000).

Immagini multi-arch `linux/amd64` + `linux/arm64` su GHCR. Funzionano nativamente su Linux, macOS e Windows con Docker Desktop, OrbStack o WSL2.

```text
ghcr.io/manprint/dind-official-full           # completa
ghcr.io/manprint/dind-official-full-minimal   # minimal
ghcr.io/manprint/dind-official-full-incus     # Incus al posto di Docker, v. README_INCUS.md
```

## Download ultima release

```bash
curl -fsSL https://github.com/manprint/dind-official-full/releases/latest/download/docker-compose.bind.yml -o docker-compose.bind.yml
docker compose -f docker-compose.bind.yml up -d
```

```bash
wget -qO docker-compose.bind.yml https://github.com/manprint/dind-official-full/releases/latest/download/docker-compose.bind.yml
docker compose -f docker-compose.bind.yml up -d
```

Versione minimal con bind mount:

```bash
curl -fsSL https://github.com/manprint/dind-official-full/releases/latest/download/docker-compose.minimal.bind.yml -o docker-compose.minimal.bind.yml
docker compose -f docker-compose.minimal.bind.yml up -d
```

```bash
wget -qO docker-compose.minimal.bind.yml https://github.com/manprint/dind-official-full/releases/latest/download/docker-compose.minimal.bind.yml
docker compose -f docker-compose.minimal.bind.yml up -d
```

I compose della release hanno l'immagine fissata alla versione; ci sono anche `docker-compose.yml` (named volumes) e `docker-compose.incus.yml` (variante Incus).

## Avvio

I compose non buildano: usano `ghcr.io/manprint/dind-official-full[-minimal]:${DIND_TAG:-latest}`, scaricata se manca in locale. Per usare un'immagine buildata a mano, `just build` (o `just build-full` / `just build-minimal`) la tagga con quei nomi e `latest`, e `docker compose up -d` la prende senza pull.

```bash
docker compose up -d
docker compose exec dind bash
```

TTY interattivo:

```bash
docker compose run --rm dind
```

Con il TTY l'output di `dockerd` va in `/var/log/dockerd.log` invece che nel terminale. `docker compose run` usa gli stessi volumi del servizio: se l'istanza di `up` è attiva, viene rifiutato (vedi [Lock sul data-root](#lock-sul-data-root)).

## Volumi

Named volumes (default):

- `docker` → `/var/lib/docker`
- `alpine-home` → `/home/alpine`

Bind mount:

```bash
docker compose -f docker-compose.bind.yml up -d
```

Default host paths: `./data/docker` e `./data/alpine-home`. Override:

```bash
DOCKER_DATA=/path/docker ALPINE_HOME=/path/home docker compose -f docker-compose.bind.yml up -d
```

La versione minimal usa di default `./data/minimal/docker` e `./data/minimal/alpine-home`:

```bash
docker compose -f docker-compose.minimal.bind.yml up -d
```

Per cambiare i percorsi:

```bash
DOCKER_DATA=/path/docker ALPINE_HOME=/path/home docker compose -f docker-compose.minimal.bind.yml up -d
```

Tag immagine:

```bash
DIND_TAG=1.0.0 docker compose up -d
```

Un dotfile in `/home/alpine` senza il marker `dind-env-` (per esempio in una home portata da fuori) viene spostato in `<nome>.dind-env-backup.<data>` e sostituito da quello dell'immagine, una volta sola.

## Variabili

| Variabile | Default | Uso |
| --- | --- | --- |
| `DIND_TAG` | `latest` | tag dell'immagine |
| `DIND_NAME` | `dind-env` / `dind-env-minimal` | nome del container |
| `DIND_TLS_PORT` | `2376` | porta host (solo `127.0.0.1`) per l'API TLS |
| `DIND_DNS` | vuoto | DNS dei container interni, es. `"10.0.0.2 10.0.0.3"` o separati da virgola |
| `DIND_ENVIRONMENT_NAME` | vuoto | nome mostrato nel prompt, es. `myenv` → `alpine@dind(myenv)` |
| `DOCKER_DAEMON_INTERNAL_BIP` | vuoto | subnet della bridge `docker0` interna, es. `10.10.100.0/24`: i container interni partono su questa rete |
| `DIND_NET_SUBNET` | `10.10.160.0/24` | subnet della rete compose del container |
| `DIND_IPV4` | `10.10.160.1` | IP del container su quella rete |
| `DIND_NET_GATEWAY` | `10.10.160.254` | gateway della rete (l'host-side della bridge) |
| `DOCKER_DATA` | `./data/docker` | solo bind: data-root di `dockerd` |
| `ALPINE_HOME` | `./data/alpine-home` | solo bind: home di `alpine` |

Senza `DIND_DNS` i container interni sulla bridge di default ripiegano su `8.8.8.8`/`8.8.4.4`: in reti che li bloccano, impostare i DNS aziendali. Le voci che non sono indirizzi IP vengono scartate con un warning, perché `dockerd` rifiuterebbe di partire. Il controllo segue le regole di `dockerd`: IPv4 a quattro ottetti senza zeri iniziali, IPv6 con gruppi di 1–4 cifre esadecimali e al massimo un `::` (`2001:db8::1::2` viene scartato: prima passava e `dockerd` non partiva). Gli IPv6 con zona (`fe80::1%eth0`) sono scartati anche se `dockerd` li accetterebbe: la zona nomina un'interfaccia del daemon, non dei container che userebbero quel DNS.

`DOCKER_DAEMON_INTERNAL_BIP` è un CIDR IPv4 con prefisso da `/8` a `/29` e diventa `--bip` di `dockerd`. Un indirizzo di rete (`10.10.100.0/24`) viene convertito nel primo host: la bridge prende `10.10.100.1/24` e i container interni da `.2` in poi. Un valore non valido viene scartato con un warning. Vale solo per la bridge di default: le reti definite dall'utente (compose incluso) usano ancora i pool di `dockerd`. Non combinarla con `--bip` nel `command:` né con `bip` in `/etc/docker/daemon.json`: `dockerd` rifiuta l'opzione data due volte (l'argomento esplicito prevale e la variabile viene ignorata con un warning). Cambiare la subnet con container interni già creati richiede di ricrearli, perché tengono l'indirizzo vecchio.

Il prompt è colorato: `utente@host` verde per `alpine` e rosso per `root`, `(DIND_ENVIRONMENT_NAME)` giallo, il branch git `(main)` ciano, poi la directory in blu, es. `alpine@dind(myenv)(main):~/progetto$`. Il branch compare dentro qualunque repository, anche per `root` in un repository di `alpine`, ed è letto da `.git/HEAD` senza eseguire `git`: niente indicatori di modifiche, e su HEAD staccato mostra l'hash corto. Senza `DIND_ENVIRONMENT_NAME` la parte `(…)` non compare. Vale per le shell che leggono `~/.bashrc`: `exec … bash`, shell di login, `sudo su`, `sudo -i`, `sudo su -`. La shell di `root` è bash (non `ash`), quindi `sudo su` dà lo stesso prompt di `exec --user root … bash`. `sudo -i` e `su -` danno a root un ambiente pulito: il nome arriva dal file `/etc/dind-environment-name`, scritto dall'entrypoint a ogni avvio.

Il container parte su una rete compose dedicata (`dind`), non su quella di default. Il container prende `10.10.160.1`, l'indirizzo che di norma Docker assegna al gateway: per questo il gateway è spostato su `10.10.160.254`. Se cambi `DIND_NET_SUBNET`, adatta anche `DIND_IPV4` e `DIND_NET_GATEWAY`, che devono stare nella nuova subnet ed essere diversi tra loro. La subnet non deve sovrapporsi a quella interna (`DOCKER_DAEMON_INTERNAL_BIP`, di default `172.17.0.0/16`) né a reti già presenti sull'host.

## Più istanze

Ogni istanza ha bisogno di nome, porta e dati propri:

```bash
DIND_NAME=dind-b DIND_TLS_PORT=2377 DIND_NET_SUBNET=10.10.161.0/24 DIND_IPV4=10.10.161.1 DIND_NET_GATEWAY=10.10.161.254 \
  DOCKER_DATA=/srv/dind-b/docker ALPINE_HOME=/srv/dind-b/home \
  docker compose -p dind-b -f docker-compose.bind.yml up -d
```

Una seconda istanza ha bisogno anche di una subnet e di un IP propri (`DIND_NET_SUBNET`, `DIND_IPV4`, `DIND_NET_GATEWAY`), perché due reti non possono avere la stessa subnet. Con `docker-compose.yml` bastano `-p`, `DIND_NAME`, `DIND_TLS_PORT` e i tre della rete: i named volumes sono già separati per progetto.

### Lock sul data-root

`dockerd` prende un lock esclusivo su `/var/lib/docker/.dind-env.lock` per tutta la sua vita. Un secondo container sullo stesso data-root (`compose run` accanto a `up`, un progetto copiato con lo stesso `DOCKER_DATA`) esce con codice 75 e questo errore nel log, senza toccare l'istanza attiva:

```text
[dind-entrypoint] ERROR: another dockerd holds /var/lib/docker/.dind-env.lock: this /var/lib/docker is in use by another container
```

Due `dockerd` sullo stesso `/var/lib/docker` lo corromperebbero. Il lock lo rilascia il kernel quando il processo muore: uno spegnimento brutale non lo lascia appeso.

## Resilienza

Pensato per staging che deve ripartire da solo dopo reboot, crash o spegnimento brutale dell'host.

- `restart: unless-stopped`: il daemon Docker dell'host riavvia il container al boot e dopo un crash, con qualunque codice di uscita.
- All'avvio lo stato runtime rimasto da uno stop non pulito (`/run/docker`, pidfile, socket) viene ripulito: senza, dopo un `kill` o una caduta di corrente `dockerd` spesso non ripartiva.
- `docker stop` è pulito: `dockerd` riceve un solo SIGTERM e ferma i container interni prima di uscire (`stop_grace_period: 60s`).
- Se `dockerd` muore da solo il container esce con codice diverso da 0 e viene riavviato; l'healthcheck (`docker version`) lo segna `unhealthy` se il daemon non risponde.
- Una chiave TLS (`/certs/{ca,server,client}/key.pem`) vuota a metà o corrotta, per esempio da un disco pieno o da una caduta di corrente durante il primo avvio, viene messa da parte (`key.pem.dind-env-corrupt.<data>`) e rigenerata con i certificati. Prima ogni avvio falliva in `openssl` e il container restava in un loop di restart da cui nessuna restart policy lo tirava fuori.

Provato dallo smoke test (v. [Test](#test)): `kill -9` del PID 1 del container dall'host (come un crash o un OOM) con la restart policy attiva, 3 cicli di `docker kill`/`docker start` con lo stato stantio lasciato sul posto, crash di `dockerd`, doppio SIGTERM, chiave TLS corrotta, ricreazione del container sugli stessi volumi: ogni volta daemon e container interni tornano su da soli.

Da fare sull'host e nei progetti interni:

- il daemon Docker dell'host deve partire al boot: `sudo systemctl enable docker`;
- i container **interni** tornano su solo con una loro restart policy (`--restart unless-stopped` o `restart:` nel compose interno);
- se `DOCKER_DATA` sta su un disco montato al boot, fare partire Docker solo dopo il mount, altrimenti il container riparte su una directory vuota creata al posto del disco: `sudo systemctl edit docker` e aggiungere

  ```ini
  [Unit]
  RequiresMountsFor=/percorso/del/disco
  ```

  Rovescio della medaglia: se il disco non si monta, sull'host non parte nessun container;

- con una VM, la cache del disco virtuale deve rispettare i flush (es. niente `cache=unsafe` in QEMU/Proxmox): altrimenti una caduta di corrente può corrompere `/var/lib/docker` qualunque cosa faccia il container;
- lo spegnimento dell'host deve lasciare a Docker il tempo di fermare i container (v. sotto, *Limiti invalicabili*).

## Limiti invalicabili

Cose che il container non può risolvere da solo: si gestiscono fuori (host, VM, applicazioni) oppure si accettano.

- **Caduta di corrente, spegnimento brutale della VM, kernel panic dell'host.** Nessuno stop ordinato è possibile: `dockerd` e i container interni muoiono di colpo. Al riavvio il container riparte e ripulisce lo stato stantio da solo (provato), ma ciò che non era ancora sul disco è perso, e l'integrità dei dati dei container interni (database e simili) dipende dal loro uso di `fsync` e da uno storage che rispetti i flush. Se a corrompersi è un database di metadati di Docker (raro: i file boltdb sotto `/var/lib/docker`, es. `network/files/local-kv.db`), `dockerd` non parte e il container resta in restart: il file indicato nel log (`docker logs`) va rimosso o ripristinato a mano, a container fermo.
- **Spegnimento ordinato dell'host: il tempo lo decide systemd.** Allo shutdown systemd ferma `docker.service` e, passato il suo `TimeoutStopSec`, lo uccide. Il default è 90 s, ma alcune macchine lo abbassano: sull'host dei test `DefaultTimeoutStopSec` è 10 s. Se è sotto lo `stop_grace_period` (60 s qui, 120 s per Incus) lo stop pulito viene troncato e il riavvio procede come dopo un crash. Da controllare e, se serve, alzare:

  ```bash
  systemctl show docker -p TimeoutStopUSec
  sudo systemctl edit docker
  ```

  ```ini
  [Service]
  TimeoutStopSec=180
  ```

- **`docker kill` e `docker stop` sono stop manuali**: con `unless-stopped` il container resta fermo, anche dopo un reboot dell'host, finché non si lancia `docker start` o `docker compose up -d`. Un crash vero (OOM, `kill -9` del processo, caduta di corrente) invece viene rialzato.
- **Se `dockerd` interno muore, muoiono i container interni.** Il container esce e viene riavviato; i container interni ripartono solo se hanno una restart policy. Non esiste `live-restore`: il daemon vive nel container stesso.
- **Timeout dei container interni.** Allo stop `dockerd` ferma i container interni, ciascuno con il suo timeout (10 s di default). Uno con `--stop-timeout`/`stop_grace_period` vicino o oltre i 60 s del container esterno riceve SIGKILL quando scade la grazia esterna: tenere i timeout interni sotto i 50 s, oppure alzare `stop_grace_period` (e il `TimeoutStopSec` dell'host).
- **Filesystem di `DOCKER_DATA`**: deve poter fare da base a overlayfs (ext4, xfs con `ftype=1`, btrfs). NFS, CIFS, FUSE o un altro overlay non sono supportati. I named volume stanno nel `/var/lib/docker` dell'host e vanno bene.
- **Un solo `dockerd` per data-root** (v. [Lock sul data-root](#lock-sul-data-root)): un secondo container sugli stessi dati resta fuori finché il primo non si ferma.
- **Sicurezza**: `privileged: true` è obbligatorio per DinD e non è un confine di sicurezza (v. Note).

## Test

```bash
docker build -t dind-test .
tests/smoke.sh dind-test 3
```

Avvio, tini, `DIND_DNS` (voci IPv4 e IPv6 non valide scartate, le altre passate a `dockerd`), `DOCKER_DAEMON_INTERNAL_BIP`, dotfile, `HOME` e prompt, lock sul data-root, `docker stop`, chiave TLS corrotta, 3 cicli di `docker kill`/`docker start`, doppio SIGTERM, crash di `dockerd`, `kill -9` del PID 1 dall'host con la restart policy, ricreazione del container sugli stessi volumi. Richiede `--privileged`, non scarica immagini, rimuove tutto ciò che crea. La pipeline di release lo esegue su ogni immagine (`tests/smoke.incus.sh` per quella Incus) prima di pubblicarne i tag.

## Note

- persistenza Docker full in `/var/lib/docker` (overlayfs/containerd snapshotter incluso)
- release GitHub su tag `vX.Y.Z`; `latest` solo sulla versione più alta
- `privileged: true` è obbligatorio per DinD
- **sicurezza**: un container privilegiato non è un confine di sicurezza. Chi controlla il container, o l'API Docker interna, controlla l'host; isola ambienti, non utenti non fidati
- `alpine` ha sudo senza password
- log rotation: 10 MB × 5 file sia per il log del container (output di `dockerd`) sia per i container interni. Se si monta un `/etc/docker/daemon.json` con `log-opts`, togliere `command:` dal compose: `dockerd` rifiuta la stessa opzione da due fonti
- timezone `Europe/Rome`, locale `it_IT.UTF-8`
- bashrc Ubuntu-like per `alpine` e `root` (prompt git a colori, alias `ll`/`tree1`/`tree2`/`tree3`); `~/go/bin`, `~/.cargo/bin`, `~/bin`, `~/.local/bin` nel `PATH`
- `pm2` + `pm2-logrotate` avviati all'avvio; le app salvate con `pm2 save` vengono ripristinate e fermate in modo pulito allo stop
- `rclone` ultima release (checksum verificato), fuse `user_allow_other`
- `tar` e `coreutils` GNU al posto degli applet busybox

La versione minimal mantiene la logica DinD, l'utente `alpine`, sudo, rclone, fuse e la gestione dei bind mount, ma non installa Rust, GitHub CLI, toolchain C/C++, Node.js/npm, PM2, Java, Python, TypeScript o Angular CLI.

Una variante con Incus al posto di Docker (container di sistema, UI web, API per OpenTofu) è descritta in [README_INCUS.md](README_INCUS.md). Le istanze si creano con gli script bash o con il template OpenTofu: guide in [incus_by_script.md](incus_by_script.md) e [incus_by_terraform.md](incus_by_terraform.md).
