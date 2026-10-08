# Istanze Incus con OpenTofu/Terraform

Guida operativa al template OpenTofu `/opt/incus-template/terraform`: come si usa, tutte le variabili, cosa succede quando le cambi, backup e restore, ricostruzione dello stato. Il container `incus-env` è descritto in [README_INCUS.md](README_INCUS.md), gli script bash equivalenti in [incus_by_script.md](incus_by_script.md). Una guida più breve è nel template stesso: [scripts/terraform/README.md](scripts/terraform/README.md).

Tutto si fa **dentro il container**, come `alpine`:

```bash
docker exec -it incus-env bash
```

Le misure citate vengono da un container `incus-env` (Incus 7.5.1, OpenTofu 1.13.1, provider `lxc/incus` 1.2.0, pool `dir`) su un host Linux 7.0 con cgroup v2.

## 1. Cosa crea

La stessa istanza di `create_incus_<distro>.sh`, come risorse OpenTofu:

| Risorsa | Cosa è |
|---|---|
| `incus_instance.this` | l'istanza: immagine, profili, limiti, swap, sicurezza, device (`root`, `eth0`, `ssh`, altri) e il provisioning (`exec`, eseguito **una volta**, alla creazione) |
| `terraform_data.guest` | l'impronta (sha256) dello script del guest e delle sue impostazioni: se cambia, l'istanza viene ricreata (`replace_triggered_by`) |
| `data.incus_profile.this` | i profili letti per copiarne `root` ed `eth0` quando li sovrascrivi |

| Differenza con gli script | Script bash | OpenTofu |
|---|---|---|
| Rilancio senza modifiche | errore (*already exists*) | non fa nulla |
| Modifiche dopo la creazione | a mano con `incus config` | si cambia la variabile e `tofu apply` |
| Provisioning fallito | istanza a metà | istanza *tainted*, errore con l'output dello script |
| Distro | uno script per distro | una variabile `distro` |
| Cancellazione | `incus delete` | `tofu destroy` |

## 2. Primo uso

```bash
cp -r /opt/incus-template/terraform ~/web     # una copia per istanza, sotto la home
cd ~/web
cp terraform.tfvars.example terraform.tfvars  # decommenta e cambia quello che serve
tofu init                                      # offline: il provider è nell'immagine
tofu plan
tofu apply
tofu output                                    # name, ipv4, ipv6, user, ssh
tofu output -raw user_password
```

| Regola | Perché |
|---|---|
| La copia sta sotto `/home/alpine` | `/opt` è nello strato del container: ricreandolo, lo stato si perde e l'istanza resta orfana. `plan`/`apply` dentro `/opt/incus-template` si rifiutano (*Copy the template under your home first*) |
| Una directory = un'istanza = uno stato | due copie con lo stesso `instance_name` si scontrano: la seconda `apply` fallisce con *already exists* senza toccare la prima |
| `terraform.tfvars` nella copia | descrive l'istanza e resta con il suo stato; le `TF_VAR_*` esportate invece valgono per tutte le copie su cui lavori da quella shell |

### File della copia

| File | Cosa contiene | Da modificare? | Nel backup? |
|---|---|---|---|
| `terraform.tfvars` | le tue impostazioni | sì | sì |
| `terraform.tfvars.example` | tutte le variabili commentate, con i default | no | — |
| `terraform.tfstate` (+ `.backup`) | lo stato: id delle risorse, configurazione, **password in chiaro** | mai a mano | sì, privato |
| `.terraform.lock.hcl` | versione e hash del provider | no | sì |
| `.terraform/` | provider collegato da `tofu init` | no | no (si rifà con `tofu init`) |
| `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf` | il template | solo se sai cosa fai (§7) | sì |
| `guest/<distro>.sh` | provisioning, identico al blocco degli script | v. §7 | sì |
| `tests/` | 53 test con il provider simulato (`tofu test`) | no | — |
| `snapshots.tf` (tuo, facoltativo) | snapshot gestiti (§8) | sì | sì |

## 3. Impostare le variabili

| Modo | Esempio | Precedenza |
|---|---|---|
| Ambiente | `TF_VAR_instance_memory=4GiB tofu apply` | la più debole |
| `terraform.tfvars` | `instance_memory = "4GiB"` | sopra `TF_VAR_*` |
| `*.auto.tfvars` | `limits.auto.tfvars` | sopra `terraform.tfvars` |
| Riga di comando | `tofu apply -var instance_memory=4GiB`, `-var-file=altro.tfvars` | la più forte |

Liste e mappe nell'ambiente vanno in HCL: `TF_VAR_extra_packages='["htop","tmux"]'`, `TF_VAR_instance_config='{"limits.processes"="500"}'`.

## 4. Variabili

Colonna **Cambio**: cosa fa `tofu apply` se la cambi dopo la creazione.

| Simbolo | Significato |
|---|---|
| **posto** | modifica sul posto, l'istanza resta |
| **posto + riavvio** | sul posto, ma vale dal prossimo avvio: `incus restart NOME` |
| **ricrea** | l'istanza viene cancellata e rifatta: **i dati dentro si perdono** |

### Istanza

| Variabile | Default | Cosa fa | Cambio |
|---|---|---|---|
| `distro` | `debian13` | `alpine`, `debian13`, `ubuntu2404`, `ubuntu2604`, `fedora`: immagine, utente e provisioning di default | ricrea |
| `remote` | `""` | remote del client `incus` (`incus remote list`); vuoto = il daemon locale | — |
| `project` | `""` | progetto Incus; vuoto = `default` | ricrea (non provato) |
| `instance_name` | `""` → `<distro>-dev` | nome e hostname (fino a 63 caratteri, inizia con una lettera) | ricrea (entra nel provisioning) |
| `instance_image` | `""` → quella della distro | immagine | ricrea |
| `instance_profiles` | `["default"]` | profili, in ordine | posto |
| `instance_storage_pool` | `""` | pool del disco root (`incus launch -s`): disco nuovo, niente dal profilo | non provato: spostare un'istanza è `incus move --storage` |
| `instance_disk_size` | `""` | dimensione del disco root (copia quello del profilo) | posto; solo pool btrfs/lvm/zfs, sul pool `dir` non limita nulla |
| `instance_network` | `""` | rete gestita di `eth0` (`incus launch -n`) | posto + riavvio (non provato) |
| `instance_ipv4` | `""` (DHCP) | IPv4 fisso (copia `eth0` del profilo e fissa l'indirizzo) | posto + riavvio |
| `instance_memory` | `"2GiB"` | `limits.memory`; `""` = nessun limite | posto, **subito** |
| `instance_cpu` | `"2"` | `limits.cpu`: numero o insieme (`0-3`); `""` = nessun limite | posto, subito |
| `instance_swap` | `""` (nessuna) | swap usabile: `512MiB`, `1GiB`…; `"0"`/`off`/`none`/`no` = nessuna | posto + riavvio |
| `instance_nesting` | `true` | `security.nesting` (Docker nell'istanza) | posto + riavvio |
| `instance_intercept` | `true` | `security.syscalls.intercept.mknod/setxattr/sysinfo`; **senza effetto se privilegiata** | posto + riavvio |
| `instance_privileged` | `false` | `security.privileged` | posto + riavvio (Incus rimappa gli uid) |
| `instance_autostart` | `true` | `boot.autostart`: riparte con Incus | posto |
| `instance_config` | `{}` | altre chiavi Incus, applicate per ultime (vincono) | posto (le `security.*` dal riavvio) |
| `instance_devices` | `{}` | altri device `nome = { type, properties }`; `root`, `eth0`, `ssh` sostituiscono quelli del template | posto |
| `instance_ssh_publish_port` | `null` | porta del container `incus-env` inoltrata alla 22 (device `proxy` `ssh`) | posto |
| `wait_network_seconds` | `90` | attesa che il guest risolva il mirror prima del provisioning; `0` = non aspettare | nessun effetto dopo la creazione |

### Guest (provisioning, solo alla creazione)

Tutte **ricreano** l'istanza se cambiate con `provision = true`: il piano dice *will be replaced due to changes in replace_triggered_by*.

| Variabile | Default | Cosa fa |
|---|---|---|
| `provision` | `true` | `false` = immagine nuda, nessun provisioning |
| `provision_timeout` | `"30m"` | tempo massimo del provisioning (non ricrea: non entra nell'impronta) |
| `user_name` | `""` → `alpine`/`debian`/`ubuntu`/`fedora` | utente (non `root`) |
| `user_uid` | `1000` | uid e gid |
| `user_password` | `"password"` | password (ssh, sudo); **in chiaro nello stato** |
| `user_shell` | `"/bin/bash"` | shell di login |
| `user_sudo` / `user_sudo_nopasswd` | `true` / `false` | gruppo `sudo`/`wheel`; sudo senza password |
| `timezone`, `locale`, `keymap` | `Europe/Rome`, `it_IT.UTF-8`, `it` | ora, lingua, tastiera |
| `ssh_password_auth` | `"yes"` | `PasswordAuthentication` (`yes`/`no`) |
| `ssh_permit_root` | `"no"` | `PermitRootLogin` (`yes`/`no`/`prohibit-password`) |
| `install_docker` | `true` | Docker + Compose |
| `docker_source` | `"official"` | `official` o `distro`; ignorata per Alpine |
| `docker_log_max_size` / `docker_log_max_file` | `"10m"` / `5` | rotazione dei log di Docker |
| `install_net_tools` | `true` | strumenti di rete |
| `install_rclone` / `rclone_release` | `true` / `"current"` | rclone e versione |
| `extra_packages` | `[]` | altri pacchetti della distro |

Cosa installano gli script, per distro: [incus_by_script.md §3](incus_by_script.md#3-variabili).

### Controlli prima di toccare Incus

`plan` si ferma con un messaggio chiaro se: distro non valida, nome non valido, IPv4 non valido, swap non riconosciuta, porta fuori da 1–65535, `ssh_*`/`docker_source` fuori elenco, utente `root` o non valido, uid 0, password vuota, durata non valida, attesa negativa, copia dentro `/opt/incus-template`, disco o IP senza un device del profilo da copiare (*set instance_storage_pool* / *set instance_network*).

## 5. Uscite

| Uscita | Valore |
|---|---|
| `name` | nome dell'istanza |
| `ipv4`, `ipv6` | indirizzi a fine `apply`; vuoti se non ancora assegnati. `tofu apply -refresh-only` li rilegge |
| `user` | utente creato (`null` con `provision = false`) |
| `ssh` | comando di accesso, più la porta pubblicata se c'è |
| `user_password` | sensibile: `tofu output -raw user_password` |

Accesso: `incus exec NOME -- su - UTENTE`, `ssh UTENTE@IP` dal container, oppure dall'host sulla porta `instance_ssh_publish_port`. Per quest'ultima la stessa porta va pubblicata anche nel compose (`ports: - "127.0.0.1:2222:2222"`): il device `proxy` ascolta nel container, non sull'host.

## 6. Modificare un'istanza

Leggi sempre il piano prima di confermare:

| Nel piano | Significa |
|---|---|
| `~ update in-place` | modifica sul posto |
| `-/+ destroy and then create replacement` | **ricreazione**: dati persi |
| `# forces replacement` | l'attributo che la causa |
| `will be replaced due to changes in replace_triggered_by` | è cambiata un'impostazione del guest |

### Cambi frequenti

| Voglio… | In `terraform.tfvars` | Poi |
|---|---|---|
| più RAM | `instance_memory = "4GiB"` | `tofu apply` (subito) |
| più CPU | `instance_cpu = "4"` | `tofu apply` |
| swap | `instance_swap = "2GiB"` | `tofu apply` + `incus restart NOME` |
| istanza non privilegiata | `instance_privileged = false` | `tofu apply` + `incus restart NOME` |
| IP fisso | `instance_ipv4 = "10.10.200.60"` | `tofu apply` + `incus restart NOME` + `tofu apply -refresh-only` (aggiorna le uscite `ipv4`/`ssh`) |
| porta ssh | `instance_ssh_publish_port = 2223` | `tofu apply` (+ `ports:` nel compose) |
| un'altra porta | `instance_devices = { web = { type = "proxy", properties = { listen = "tcp:0.0.0.0:8081", connect = "tcp:127.0.0.1:80" } } }` | `tofu apply` (+ `ports:`) |
| cartella condivisa | `instance_devices = { data = { type = "disk", properties = { source = "/home/alpine/shared", path = "/data", shift = "true" } } }` | `tofu apply` |
| una chiave Incus | `instance_config = { "limits.processes" = "500", "boot.autostart.priority" = "10" }` | `tofu apply` |
| snapshot automatici | `instance_config = { "snapshots.schedule" = "@daily", "snapshots.expiry" = "7d" }` | `tofu apply` |

Note:
- **`shift = "true"`** serve nelle istanze non privilegiate: senza, i file dell'utente 1000 compaiono come `65534` e non sono scrivibili (misurato con gli script, stesso device). `source` è un percorso del container: `/home/alpine` è `ALPINE_HOME` sull'host.
- **`instance_config` con `raw.lxc`** sostituisce la riga dello swap del template: se la usi, rimetti dentro anche `lxc.cgroup2.memory.swap.max = <byte>`.
- RAM, swap e cosa mostrano i tool: *[Gestione RAM e swap](README_INCUS.md#gestione-ram-e-swap)*.

### Cose da non fare con le variabili

| Voglio… | Non così (ricrea) | Così |
|---|---|---|
| cambiare password | `user_password` | `incus exec NOME -- passwd UTENTE` |
| installare un pacchetto | `extra_packages` | `incus exec NOME -- apk add …` / `apt-get install …` / `dnf install …` |
| cambiare fuso orario, sudo, ssh | `timezone`, `user_sudo_nopasswd`, `ssh_*` | a mano nell'istanza, come in [incus_by_script.md §6](incus_by_script.md#6-modificare-unistanza-esistente) |
| rinominare | `instance_name` | ricrea per forza: per tenere i dati, `incus copy` + import nello stato nuovo (§8, *Clonare con i dati*) |

Se l'istanza è gestita da OpenTofu, **non cambiare a mano con `incus config set`** ciò che il template imposta: limiti, swap, sicurezza, device. Il prossimo `apply` rimette i valori del file. Le chiavi che il template non tocca (es. `snapshots.*` messe a mano) invece restano.

### Ricreare, tenere, cancellare

| Cosa | Comando |
|---|---|
| Ricreare da zero | `tofu apply -replace=incus_instance.this` |
| Provisioning fallito: tenere l'istanza com'è | `tofu untaint incus_instance.this` |
| Provisioning fallito: guardarci dentro | `incus exec NOME -- sh` (l'errore di `apply` riporta stdout/stderr dello script) |
| Rileggere IP e stato | `tofu apply -refresh-only` |
| Cancellare | `tofu destroy`: cancella anche **tutti** gli snapshot dell'istanza, compresi quelli fatti a mano (misurato) |

## 7. Modificare il template

| Cosa | Come | Effetto sulle istanze esistenti |
|---|---|---|
| Default diversi per una copia | `terraform.tfvars` (non `variables.tf`) | come cambiare le variabili |
| Provisioning (`guest/<distro>.sh`) | modifica il file nella copia | ricrea (l'impronta comprende lo script) |
| Nel repository | lo script vero è il blocco `<<'GUEST'` di `create_incus_<distro>.sh`; `tests/terraform.sh --fix` copia gli heredoc in `guest/*.sh` e controlla che variabili e default restino allineati | — |
| Provare | `tofu test` nella copia (53 test, provider simulato, senza Incus); `MODE=tofu tests/templates.sh` nel repository su un Incus vero | — |
| Un'altra versione del provider | `~/.tofurc` con `provider_installation { direct {} }`, poi `tofu init -upgrade` (serve internet) | — |

## 8. Backup e restore

Per un'istanza gestita da OpenTofu i pezzi da salvare sono due: i **dati** dell'istanza (Incus) e la **directory** con lo stato (OpenTofu).

| Cosa salvare | Come | Contiene |
|---|---|---|
| Dati dell'istanza | `incus export` (a caldo) o backup a freddo dell'ambiente | filesystem, configurazione, snapshot |
| Directory della copia | `tar`/`rsync` di `~/web` (senza `.terraform/`) | `terraform.tfvars`, `terraform.tfstate`, `.terraform.lock.hcl`, eventuali `.tf` tuoi |

Lo stato contiene la password in chiaro: tienilo privato come il backup stesso. Il backup a freddo di `ALPINE_HOME` comprende già le copie del template, se stanno nella home.

### Snapshot

| Modo | Come | Effetto sul piano |
|---|---|---|
| A mano | `incus snapshot create NOME prima-di-upgrade` | nessuno: `plan` resta *No changes* (misurato) |
| Gestito | risorsa `incus_instance_snapshot` (sotto) | lo snapshot nasce con `apply`, muore con `destroy` |
| Automatico | `instance_config = { "snapshots.schedule" = "@daily", "snapshots.expiry" = "7d" }` | gestito dal daemon |

Snapshot gestito, in un file `snapshots.tf` della copia:

```hcl
resource "incus_instance_snapshot" "pre_upgrade" {
  name     = "pre-upgrade"
  instance = incus_instance.this.name
}
```

| Operazione | Comando | Note (misurate) |
|---|---|---|
| Crearlo | `tofu apply` | *1 to add* |
| Toglierlo solo lui | `tofu destroy -target=incus_instance_snapshot.pre_upgrade` | l'istanza resta |
| Rifarlo (nuovo punto di ripristino) | `tofu apply -replace=incus_instance_snapshot.pre_upgrade` | |
| Ripristinarlo | `incus snapshot restore NOME pre-upgrade` | il provider non ha un "restore": si fa con il client |
| Nome già esistente in Incus | `apply` fallisce: *Failed to create snapshot "pre-upgrade"* | `incus snapshot rename NOME pre-upgrade pre-upgrade-old`, poi `apply` |
| Importarlo nello stato | non si può: *Resource Import Not Implemented* | rinominalo come sopra, oppure togli la risorsa |
| Con la memoria (`stateful = true`) | non disponibile | serve CRIU, che l'immagine non ha |

**Dopo un `incus snapshot restore`** l'istanza si riavvia (~2 s) e torna la configurazione dello snapshot. Un `plan` lanciato subito può mostrare `ipv4 = "…" -> ""`: l'IP non è ancora tornato. Dopo pochi secondi il piano è di nuovo *No changes* (misurato). Se tra lo snapshot e il restore hai cambiato una variabile (es. la RAM), il piano la riapplica: è il comportamento giusto.

### Export e import

```bash
mkdir -p ~/backups
incus export NOME ~/backups/NOME-$(date +%F).tar.gz      # --instance-only per escludere gli snapshot
tar -czf ~/backups/NOME-tofu-$(date +%F).tar.gz --exclude=.terraform -C ~ web
```

| Situazione | Procedura | Risultato (misurato) |
|---|---|---|
| Istanza persa o rovinata, stato intatto | 1. `incus delete -f NOME` (se esiste); 2. `incus import ~/backups/NOME-….tar.gz`; 3. `incus start NOME`; 4. `tofu plan` | *No changes*: lo stato riconosce l'istanza dal nome. Tornano file, Docker, snapshot |
| Stato perso, istanza intatta | ricostruzione dello stato (sotto) | *No changes*, provisioning **non** rieseguito |
| Persi entrambi | ripristina la directory dal suo backup, poi la prima riga | |
| Ambiente intero | backup a freddo di `INCUS_DATA` + `ALPINE_HOME`, v. [incus_by_script.md §8](incus_by_script.md#backup-a-freddo-dellambiente) | istanze e copie del template tornano insieme |

**Non lanciare `tofu apply` mentre l'istanza manca.** Il piano dice *incus_instance.this has been deleted … will be created*: `apply` creerebbe un'istanza nuova, vuota, con lo stesso nome, e l'import del backup poi fallirebbe. Prima `incus import`, poi `tofu plan`.

### Ricostruire lo stato perso

Con un `tofu import` semplice il piano **ricrea** l'istanza: l'immagine non risulta (*forces replacement*) e `terraform_data.guest` manca (*replace_triggered_by*). La sequenza giusta, misurata:

```bash
cd ~/web                                          # la copia, con il terraform.tfvars dell'istanza
rm -f terraform.tfstate terraform.tfstate.backup  # solo se sono rotti/persi
tofu init
tofu apply -target=terraform_data.guest           # 1. l'impronta del guest, prima dell'istanza
tofu import incus_instance.this "NOME,image=images:alpine/3.24"   # 2. l'istanza, con la sua immagine
tofu plan                                         # 3. deve dire: 1 to change, 0 to destroy (exec)
tofu apply                                        # 4. registra exec; il provisioning NON gira di nuovo
tofu plan                                         # 5. No changes
```

| Passo | Perché |
|---|---|
| `-target=terraform_data.guest` prima | se l'impronta nasce dopo l'istanza, `replace_triggered_by` la ricrea |
| `,image=…` nell'ID | senza, l'immagine risulta cambiata e *forces replacement*. Usa l'immagine della distro (`instance_image` o quella di default, §1 di incus_by_script.md) |
| piano con `+ exec` in-place | normale: lo stato importato non ha i comandi di provisioning. `apply` li registra senza eseguirli (misurato: i file scritti dal provisioning non cambiano) |
| `snapshots.tf` | gli snapshot gestiti non si importano: prima del passo 3 rinomina in Incus quelli che esistono già, o togli il file |

Se il piano al passo 3 mostra `-/+` o *forces replacement*, **non confermare**: qualcosa in `terraform.tfvars` non corrisponde all'istanza (immagine, nome, progetto). Correggi e ripeti.

### Clonare con i dati

Una nuova copia del template con un altro `instance_name` crea un'istanza **nuova** e provisionata da zero, senza i dati. Per un clone con i dati:

```bash
incus copy web web2                                    # anche da accesa
cp -r ~/web ~/web2 && cd ~/web2 && rm -f terraform.tfstate*
# terraform.tfvars: instance_name = "web2", e un altro instance_ipv4 / instance_ssh_publish_port se usati
tofu init
tofu apply -target=terraform_data.guest
tofu import incus_instance.this "web2,image=images:alpine/3.24"
tofu apply                                             # IP/porta nuovi (+ exec): avvia anche l'istanza
incus exec web2 -- sh -c 'echo web2 > /etc/hostname; hostname web2'
tofu apply -refresh-only                               # uscite con l'IP nuovo
```

`incus copy` genera un MAC nuovo, ma IP fisso e porta pubblicata restano quelli dell'originale. L'`apply` li cambia e avvia la copia, perché il provider tiene le istanze accese. Misurato tutto di fila: clone `RUNNING` sul suo IP con file e container Docker dell'originale, provisioning non rieseguito, piano *No changes* su entrambe le copie.

## 9. Più istanze, altri server

| Caso | Come |
|---|---|
| Più istanze | una copia per istanza (`~/web`, `~/db`…), ognuna con `instance_name` diverso |
| Stesse impostazioni comuni | un file `comune.tfvars` e `tofu apply -var-file=../comune.tfvars` (vince su `terraform.tfvars`) |
| Un altro server Incus | sul server `incus config trust add NOME` → token; qui `incus remote add lab TOKEN`; poi `remote = "lab"` |
| Da fuori del container | provider configurato con `address`/`token` verso la porta 8443 pubblicata (v. *API, web UI, OpenTofu/Terraform* in README_INCUS) |

## 10. Problemi frequenti

| Messaggio / sintomo | Causa | Soluzione |
|---|---|---|
| *Copy the template under your home first* | copia dentro `/opt/incus-template` | `cp -r /opt/incus-template/terraform ~/NOME` |
| *already exists* all'`apply` | un'altra istanza ha quel nome | `instance_name` diverso, oppure importala (§8) |
| *no available releases match* a `tofu init` | versione del provider assente dal mirror dell'immagine | `~/.tofurc` con `direct {}` (§7) |
| *Still creating...* per minuti | provisioning in corso; l'output si vede solo se fallisce | attendi (`provision_timeout`) |
| istanza *tainted* | provisioning fallito | guarda l'errore, `incus exec NOME -- sh`; poi `apply` (ricrea) o `untaint` |
| piano con `-/+` inatteso | variabile del guest cambiata (anche `instance_name`, `distro`) | ripristina il valore o accetta la ricreazione sapendo che i dati si perdono |
| `ipv4 = "…" -> ""` nel piano | istanza appena riavviata | ripeti tra qualche secondo |
| *Failed to create snapshot* | snapshot con quel nome già in Incus | `incus snapshot rename` |
| *Resource Import Not Implemented* | `tofu import` di uno snapshot | non supportato dal provider |
| `free` mostra la RAM dell'host | Alpine privilegiata | `instance_privileged = false`, v. [Gestione RAM e swap](README_INCUS.md#gestione-ram-e-swap) |
| `tofu destroy` ha tolto anche gli snapshot manuali | `destroy` cancella l'istanza con i suoi snapshot | backup con `incus export` prima |
