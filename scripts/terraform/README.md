# Template OpenTofu/Terraform per le istanze Incus

Crea la stessa istanza di sviluppo degli script `create_incus_<distro>.sh`, ma con OpenTofu (`tofu`, già nell'immagine) o Terraform. L'istanza ha limiti, nesting per Docker, indirizzo fisso e porta ssh facoltativi. Poi viene il provisioning del guest: utente, lingua, ssh, sudo, Docker, rclone e strumenti.

Il provisioning è lo script di `create_incus_<distro>.sh` copiato byte per byte in `guest/<distro>.sh`. Le impostazioni sono le stesse variabili degli script, in minuscolo e con gli stessi default.

Dove si trova:
- nell'immagine: `/opt/incus-template/terraform` (proprietà `alpine`);
- nel repository: `scripts/terraform`.

## Uso

```bash
cp -r /opt/incus-template/terraform ~/incus-dev   # lo stato vive nella copia, sotto la home (un volume)
cd ~/incus-dev
tofu init                                          # offline: il provider è già nell'immagine
tofu apply                                         # debian13-dev, come create_incus_debian13.sh
tofu output                                        # nome, ipv4, ipv6, utente, comando ssh
tofu output -raw user_password
tofu destroy
```

`tofu plan` e `tofu apply` si rifiutano di girare dentro `/opt/incus-template/terraform` (*Copy the template under your home first*). Il motivo: `/opt` sta nello strato scrivibile del container, quindi ricreando il container lo stato andrebbe perso e l'istanza resterebbe senza nessuno che la gestisce. `/home/alpine` invece è un volume.

Usa una copia per istanza: ogni directory ha il suo stato. Il nome di default è `<distro>-dev`, quindi due copie con la stessa distro hanno lo stesso nome. In quel caso la seconda `apply` fallisce con *already exists* e non tocca la prima: imposta `instance_name`.

## Impostazioni

Le variabili sono quelle degli script in minuscolo (`INSTANCE_MEMORY` diventa `instance_memory`), con gli stessi default. L'elenco completo e commentato è in `terraform.tfvars.example`; descrizioni e controlli sono in `variables.tf`. Ci sono tre modi per impostarle:

```bash
# 1. ambiente
TF_VAR_distro=alpine TF_VAR_instance_name=web TF_VAR_instance_memory=4GiB tofu apply
TF_VAR_extra_packages='["htop","tmux"]' TF_VAR_instance_config='{"limits.processes"="500"}' tofu apply

# 2. file: terraform.tfvars e *.auto.tfvars della directory vengono letti da soli
cp terraform.tfvars.example terraform.tfvars     # poi decommenta quello che cambi
tofu apply
tofu apply -var-file=web.tfvars                  # un altro file, indicato a mano

# 3. riga di comando
tofu apply -var instance_memory=4GiB
```

Precedenza, dalla più debole alla più forte: `TF_VAR_*`, poi `terraform.tfvars`, poi `*.auto.tfvars`, poi `-var`/`-var-file`.

Per un'istanza da tenere conviene `terraform.tfvars` nella sua copia. Le `TF_VAR_*` esportate valgono invece per tutte le copie su cui lavora quella shell.

Differenze rispetto agli script:

| Script bash | OpenTofu |
|---|---|
| `INCUS_REMOTE=lab` | `remote = "lab"` |
| `INSTANCE_PROFILES="default extra"` | `instance_profiles = ["default", "extra"]` |
| `INSTANCE_CONFIG="limits.processes=500"` | `instance_config = { "limits.processes" = "500" }` |
| `EXTRA_PACKAGES="htop tmux"` | `extra_packages = ["htop", "tmux"]` |
| `INSTANCE_SSH_PUBLISH_PORT=2222` (vuoto = no) | `instance_ssh_publish_port = 2222` (`null` = no) |
| `INSTANCE_RECREATE=true` | `tofu apply -replace=incus_instance.this` |
| `WAIT_NETWORK_SECONDS=90` | `wait_network_seconds = 90`; `0` = non aspettare la rete |
| non esiste | `distro`: `alpine`, `debian13` (default), `ubuntu2404`, `ubuntu2604`, `fedora` |
| non esiste | `project`; `instance_devices` (altri device, o sostituti di `root`/`eth0`/`ssh`); `provision = false` (immagine nuda); `provision_timeout` (`30m`) |

Disco e rete seguono `incus launch`:
- `instance_storage_pool` e `instance_network` creano un disco root o una `eth0` nuovi su quel pool o su quella rete;
- `instance_disk_size` da solo copia il disco root del profilo e ne cambia la dimensione;
- `instance_ipv4` da solo copia la `eth0` del profilo e fissa l'indirizzo;
- se i profili non hanno quel device, il piano si ferma e dice cosa impostare.

I valori vengono controllati prima di toccare Incus. Sono controllati:
- la distro e il nome dell'istanza;
- l'indirizzo IPv4;
- lo swap (`512MiB`, `1GiB`, `0`/`off`);
- la porta ssh pubblicata;
- `ssh_*` e `docker_source`;
- l'utente (non può essere `root`) e l'uid (maggiore di 0);
- la password (non può essere vuota);
- `provision_timeout` (una durata, es. `30m`) e `wait_network_seconds` (non negativo).

## Cosa succede quando cambi qualcosa

Il piano lo dice sempre: `~` è una modifica sul posto, mentre `-/+` ricrea l'istanza e i suoi dati vanno persi. Leggilo prima di confermare.

- **Impostazioni dell'istanza** (`instance_*`: limiti, swap, configurazione, device, profili): cambiano sul posto, senza fermare l'istanza. Memoria e CPU valgono subito. Lo swap (`raw.lxc`) e le chiavi `security.*` valgono dal prossimo avvio dell'istanza (`incus restart NOME`).
- **Impostazioni del guest** (`user_*`, `timezone`, `locale`, `keymap`, `ssh_*`, `install_*`, `docker_*`, `rclone_release`, `extra_packages`, `provision`, più `guest/<distro>.sh`): servono una volta sola, alla creazione. Cambiarne una **ricrea l'istanza**, e il piano lo segnala con *will be replaced due to changes in replace_triggered_by*. Anche `distro` e `instance_name` entrano nel provisioning: con `provision = true` ricreano l'istanza anche loro. Per cambiare la password di un'istanza che esiste già usa `passwd` dentro l'istanza, non la variabile.
- **Provisioning fallito**: l'`apply` finisce con un errore che riporta l'output dello script (stdout e stderr). L'istanza resta, segnata *tainted*, così puoi guardarci dentro (`incus exec NOME -- sh`). Il prossimo `tofu apply` la ricrea da capo; `tofu untaint incus_instance.this` la tiene così com'è.
- Durante il provisioning si vede solo *Still creating...*, per i tempi degli script: da circa 20 s per Alpine a qualche minuto per Fedora. L'output dello script compare solo se fallisce. Nel piano `exec` appare come *(sensitive value)* perché contiene la password.

## Uscite

`tofu output` mostra `name`, `ipv4`, `ipv6`, `user` e `ssh`, come la riga finale degli script. `ssh` è il comando di accesso (es. `ssh debian@10.10.200.23`), più la porta pubblicata se c'è. La password si legge con `tofu output -raw user_password`.

Gli indirizzi sono quelli di fine `apply`. Se l'indirizzo cambia (DHCP, riavvio), `tofu apply -refresh-only` lo rilegge.

## Provider e versioni

**Provider `lxc/incus` 1.2.0**, l'ultima versione al momento del build:
- è già nell'immagine, in `/usr/share/terraform/plugins`, il mirror locale implicito di OpenTofu;
- `tofu init` lo collega con un symlink e non scarica nulla (provato con `--network none`);
- `Installed lxc/incus v1.2.0 (unauthenticated)` è normale per un mirror locale: l'integrità la verificano gli hash di `.terraform.lock.hcl`, e la firma del registry (chiave `C638974D64792D67`) è stata verificata al build.

**Un'altra versione del provider.** Un provider presente nel mirror si prende solo da lì, anche con `tofu init -upgrade`: una versione che il mirror non ha dà *no available releases match*. Per scaricarla dal registry serve `~/.tofurc`:

```hcl
provider_installation {
  direct {}
}
```

**Versioni di OpenTofu e Terraform:**
- il template richiede OpenTofu ≥ 1.6; `tofu test` richiede ≥ 1.8 (mock del provider);
- provato con OpenTofu 1.13.1, quello dell'immagine;
- provato anche con HashiCorp Terraform 1.16.5 (`init`, `validate`, `test`): Terraform prende il provider da `registry.terraform.io` e aggiunge la sua voce a `.terraform.lock.hcl`.

## Un altro server Incus

Il provider usa la configurazione del client `incus` (`~/.config/incus`), come gli script. Nel container il remote di default è il daemon locale.

Per un altro server:
1. sul server, `incus config trust add NOME` stampa un token;
2. qui, `incus remote add lab TOKEN`;
3. imposta `remote = "lab"` (oppure `TF_VAR_remote=lab`).

## Sicurezza

- **La password è in chiaro nello stato.** `user_password` (default `password`) finisce in chiaro in `terraform.tfstate` e in un piano salvato con `-out`; `sensitive` la nasconde solo nell'output. Tieni la copia privata. Se la metti in git, `.gitignore` esclude già lo stato, i `*.tfvars` e `.terraform/`.
- **Cambia la password debole prima di esporre l'istanza**, oppure usa `ssh_password_auth = "no"` con le chiavi, come per gli script.

## Test

```bash
tofu test     # nella copia: 53 test con il provider simulato, senza Incus
```

`tests/terraform.tfvars` rimette ogni variabile al suo default, solo per i test. Vale più delle `TF_VAR_*` e dei `*.tfvars` della copia, quindi i test passano qualunque sia la configurazione. Non usarlo per configurare l'istanza.

Nel repository:
- `tests/terraform.sh` (`just test-terraform`) controlla anche che il template resti allineato agli script bash;
- `tests/smoke.incus.sh` e `MODE=tofu tests/templates.sh` lo provano su un Incus vero.
