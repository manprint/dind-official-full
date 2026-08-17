# dind-env

`docker:29.7.2-dind` + toolchain di sviluppo. `dockerd` resta root (comportamento DinD); la sessione parte come `alpine` (uid/gid 1000).

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

## Avvio

```bash
docker compose up --build -d
docker compose exec dind bash
```

TTY interattivo:

```bash
docker compose run --rm dind
```

## Volumi

Named volumes (default):

- `docker` → `/var/lib/docker`
- `alpine-home` → `/home/alpine`

Bind mount:

```bash
docker compose -f docker-compose.bind.yml up --build -d
```

Default host paths: `./data/docker` e `./data/alpine-home`. Override:

```bash
DOCKER_DATA=/path/docker ALPINE_HOME=/path/home docker compose -f docker-compose.bind.yml up -d
```

La versione minimal usa di default `./data/minimal/docker` e `./data/minimal/alpine-home`:

```bash
docker compose -f docker-compose.minimal.bind.yml up --build -d
```

Per cambiare i percorsi:

```bash
DOCKER_DATA=/path/docker ALPINE_HOME=/path/home docker compose -f docker-compose.minimal.bind.yml up -d
```

Tag immagine:

```bash
DIND_TAG=1.0.0 docker compose up -d
```

## Note

- persistenza Docker full in `/var/lib/docker` (overlayfs/containerd snapshotter incluso)
- release GitHub su tag `vX.Y.Z`
- `privileged: true` è obbligatorio per DinD
- `alpine` ha sudo senza password
- timezone `Europe/Rome`, locale `it_IT.UTF-8`
- bashrc Ubuntu-like per `alpine` e `root` (prompt git, alias `ll`/`tree1`/`tree2`/`tree3`)
- `pm2` + `pm2-logrotate` avviati all'avvio
- `rclone` ultima release, fuse `user_allow_other`

La versione minimal mantiene la logica DinD, l'utente `alpine`, sudo, rclone, fuse e la gestione dei bind mount, ma non installa Rust, GitHub CLI, toolchain C/C++, Node.js/npm, PM2, Java, Python, TypeScript o Angular CLI.
