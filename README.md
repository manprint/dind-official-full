# dind-env

`docker:29.8.2-dind` + toolchain di sviluppo. `dockerd` resta root (comportamento DinD); la sessione parte come `alpine` (uid/gid 1000).

Immagini multi-arch `linux/amd64` + `linux/arm64` su GHCR. Funzionano nativamente su Linux, macOS e Windows con Docker Desktop, OrbStack o WSL2.

```text
ghcr.io/manprint/dind-official-full
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

I compose della release hanno l'immagine fissata alla versione; c'è anche `docker-compose.yml` (named volumes).

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

Senza `DIND_DNS` i container interni sulla bridge di default ripiegano su `8.8.8.8`/`8.8.4.4`: in reti che li bloccano, impostare i DNS aziendali. Le voci che non sono indirizzi IP vengono scartate con un warning, perché `dockerd` rifiuterebbe di partire.

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

Da fare sull'host e nei progetti interni:

- il daemon Docker dell'host deve partire al boot: `sudo systemctl enable docker`;
- i container **interni** tornano su solo con una loro restart policy (`--restart unless-stopped` o `restart:` nel compose interno);
- se `DOCKER_DATA` sta su un disco montato al boot, fare partire Docker solo dopo il mount, altrimenti il container riparte su una directory vuota creata al posto del disco: `sudo systemctl edit docker` e aggiungere

  ```ini
  [Unit]
  RequiresMountsFor=/percorso/del/disco
  ```

  Rovescio della medaglia: se il disco non si monta, sull'host non parte nessun container;

- con una VM, la cache del disco virtuale deve rispettare i flush (es. niente `cache=unsafe` in QEMU/Proxmox): altrimenti una caduta di corrente può corrompere `/var/lib/docker` qualunque cosa faccia il container.

## Test

```bash
docker build -t dind-test .
tests/smoke.sh dind-test 3
```

Avvio, DNS, lock, `docker stop`, 3 cicli di `docker kill`/`docker start`, doppio SIGTERM, crash di `dockerd`. Richiede `--privileged`, non scarica immagini, rimuove tutto ciò che crea. La pipeline di release lo esegue su ogni immagine (`tests/smoke.incus.sh` per quella Incus) prima di pubblicarne i tag.

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

Una variante con Incus al posto di Docker (container di sistema, UI web, API per OpenTofu) è descritta in [README_INCUS.md](README_INCUS.md).
