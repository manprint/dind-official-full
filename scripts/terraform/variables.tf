# The settings of the bash templates (/opt/incus-template/create_incus_*.sh),
# lowercased: INSTANCE_MEMORY is instance_memory. Set them in a *.tfvars file
# (terraform.tfvars is read by itself), with -var, or in the environment as
# TF_VAR_<name>: TF_VAR_instance_memory=4GiB. Lists and maps take HCL there:
# TF_VAR_extra_packages='["htop","tmux"]'.
#
# instance_* settings are applied in place (memory, CPU, swap, disk, devices…;
# security.* and swap take effect at the next restart of the instance). The
# guest settings (user_*, locale, packages, Docker…) are used once, to provision
# the instance when it is created: changing one later replaces the instance.

variable "distro" {
  description = "Template: alpine, debian13, ubuntu2404, ubuntu2604 or fedora. Picks the default image, user and the guest provisioning script."
  type        = string
  default     = "debian13"

  validation {
    condition     = contains(["alpine", "debian13", "ubuntu2404", "ubuntu2604", "fedora"], var.distro)
    error_message = "distro must be one of: alpine, debian13, ubuntu2404, ubuntu2604, fedora."
  }
}

# ---- instance ----------------------------------------------------------------

variable "remote" {
  description = "Incus remote of the incus client configuration (`incus remote list`); empty = the default remote (INCUS_REMOTE)."
  type        = string
  default     = ""
}

variable "project" {
  description = "Incus project; empty = the default one."
  type        = string
  default     = ""
}

variable "instance_name" {
  description = "Instance name, also the hostname; empty = <distro>-dev."
  type        = string
  default     = ""

  validation {
    condition     = var.instance_name == "" || can(regex("^[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$", var.instance_name))
    error_message = "instance_name: up to 63 letters, digits and dashes, starting with a letter and not ending with a dash."
  }
}

variable "instance_image" {
  description = "Image; empty = the distro's (images:debian/13, …)."
  type        = string
  default     = ""
}

variable "instance_profiles" {
  description = "Profiles, in order."
  type        = list(string)
  default     = ["default"]
}

variable "instance_storage_pool" {
  description = "Storage pool of the root disk; empty = the profile's."
  type        = string
  default     = ""
}

variable "instance_network" {
  description = "Managed network of eth0; empty = the profile's."
  type        = string
  default     = ""
}

variable "instance_ipv4" {
  description = "Fixed IPv4 address of eth0 on its managed bridge, e.g. 10.10.200.50; empty = DHCP."
  type        = string
  default     = ""

  validation {
    condition     = var.instance_ipv4 == "" || can(cidrhost("${var.instance_ipv4}/32", 0))
    error_message = "instance_ipv4 must be an IPv4 address such as 10.10.200.50."
  }
}

variable "instance_memory" {
  description = "limits.memory, e.g. 4GiB; empty = no limit."
  type        = string
  default     = "2GiB"
}

variable "instance_cpu" {
  description = "limits.cpu: a count (2) or a set of CPUs (0-3); empty = no limit."
  type        = string
  default     = "2"
}

variable "instance_swap" {
  description = "Swap the instance may use, e.g. 1GiB or 512MiB; 0, off, none or no = none; empty = Incus default (none)."
  type        = string
  default     = ""

  validation {
    condition = (
      var.instance_swap == "" ||
      contains(["0", "off", "none", "no"], var.instance_swap) ||
      can(regex("^[0-9]+[[:space:]]*(B|K|KB|KiB|kB|M|MB|MiB|G|GB|GiB|T|TB|TiB)?$", var.instance_swap))
    )
    error_message = "instance_swap is not a size (e.g. 512MiB, 1GiB, 0)."
  }
}

variable "instance_disk_size" {
  description = "Size of the root disk, e.g. 20GiB (needs a btrfs, lvm or zfs pool); empty = the profile's."
  type        = string
  default     = ""
}

variable "instance_nesting" {
  description = "security.nesting, needed by Docker in the instance."
  type        = bool
  default     = true
}

variable "instance_intercept" {
  description = "security.syscalls.intercept.mknod/setxattr/sysinfo (sysinfo: busybox free and top see the limits)."
  type        = bool
  default     = true
}

variable "instance_privileged" {
  description = "security.privileged."
  type        = bool
  default     = false
}

variable "instance_autostart" {
  description = "boot.autostart: started again with the Incus daemon."
  type        = bool
  default     = true
}

variable "instance_config" {
  description = "More instance configuration, e.g. { \"limits.processes\" = \"500\" }; applied last, so it wins."
  type        = map(string)
  default     = {}
}

variable "instance_devices" {
  description = "More devices: name => { type, properties }; a name used by the template (root, eth0, ssh) replaces its device."
  type = map(object({
    type       = string
    properties = map(string)
  }))
  default = {}
}

variable "instance_ssh_publish_port" {
  description = "Also publish the instance's ssh on this port of the Incus host (proxy device); null = not published."
  type        = number
  default     = null

  validation {
    condition     = var.instance_ssh_publish_port == null || try(var.instance_ssh_publish_port >= 1 && var.instance_ssh_publish_port <= 65535 && floor(var.instance_ssh_publish_port) == var.instance_ssh_publish_port, false)
    error_message = "instance_ssh_publish_port must be a port number (1-65535)."
  }
}

variable "wait_network_seconds" {
  description = "How long the instance may take to resolve its distro's mirror before provisioning; 0 = do not wait."
  type        = number
  default     = 90

  validation {
    condition     = var.wait_network_seconds >= 0
    error_message = "wait_network_seconds cannot be negative."
  }
}

# ---- guest -------------------------------------------------------------------

variable "provision" {
  description = "Provision the guest (user, locale, ssh, packages, Docker, rclone); false = the bare image."
  type        = bool
  default     = true
}

variable "provision_timeout" {
  description = "Time limit of the guest provisioning, e.g. 30m."
  type        = string
  default     = "30m"

  validation {
    condition     = can(regex("^([0-9]+(\\.[0-9]+)?(ms|s|m|h))+$", var.provision_timeout))
    error_message = "provision_timeout must be a duration such as 30m or 1h."
  }
}

variable "user_name" {
  description = "User created in the guest; empty = the distro's (alpine, debian, ubuntu, fedora)."
  type        = string
  default     = ""

  validation {
    condition     = var.user_name == "" || (var.user_name != "root" && can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.user_name)))
    error_message = "user_name must be a valid user name other than root."
  }
}

variable "user_uid" {
  description = "uid (and gid) of the user."
  type        = number
  default     = 1000

  validation {
    condition     = var.user_uid >= 1 && floor(var.user_uid) == var.user_uid
    error_message = "user_uid must be a positive integer (0 is root)."
  }
}

variable "user_password" {
  description = "Password of the user (ssh, sudo). Kept in the state: keep that private."
  type        = string
  default     = "password"
  sensitive   = true

  validation {
    condition     = var.user_password != ""
    error_message = "user_password cannot be empty."
  }
}

variable "user_shell" {
  description = "Login shell of the user."
  type        = string
  default     = "/bin/bash"
}

variable "user_sudo" {
  description = "sudo for the user (sudo or wheel group)."
  type        = bool
  default     = true
}

variable "user_sudo_nopasswd" {
  description = "sudo without the password."
  type        = bool
  default     = false
}

variable "timezone" {
  description = "Timezone of the guest."
  type        = string
  default     = "Europe/Rome"
}

variable "locale" {
  description = "Locale of the guest."
  type        = string
  default     = "it_IT.UTF-8"
}

variable "keymap" {
  description = "Keyboard layout."
  type        = string
  default     = "it"
}

variable "ssh_password_auth" {
  description = "sshd PasswordAuthentication: yes or no."
  type        = string
  default     = "yes"

  validation {
    condition     = contains(["yes", "no"], var.ssh_password_auth)
    error_message = "ssh_password_auth must be yes or no."
  }
}

variable "ssh_permit_root" {
  description = "sshd PermitRootLogin: yes, no or prohibit-password."
  type        = string
  default     = "no"

  validation {
    condition     = contains(["yes", "no", "prohibit-password"], var.ssh_permit_root)
    error_message = "ssh_permit_root must be yes, no or prohibit-password."
  }
}

variable "install_docker" {
  description = "Docker and Compose in the guest."
  type        = bool
  default     = true
}

variable "docker_source" {
  description = "official (download.docker.com, docker-ce) or distro (the distribution's packages); Alpine always uses its own."
  type        = string
  default     = "official"

  validation {
    condition     = contains(["official", "distro"], var.docker_source)
    error_message = "docker_source must be official or distro."
  }
}

variable "docker_log_max_size" {
  description = "json-file log rotation of the guest's Docker: size of a file."
  type        = string
  default     = "10m"
}

variable "docker_log_max_file" {
  description = "json-file log rotation of the guest's Docker: files kept."
  type        = number
  default     = 5
}

variable "install_net_tools" {
  description = "Network debugging tools (tcpdump, nmap, mtr, iperf3, …)."
  type        = bool
  default     = true
}

variable "install_rclone" {
  description = "rclone, from downloads.rclone.org, checked against its SHA256SUMS."
  type        = bool
  default     = true
}

variable "rclone_release" {
  description = "rclone version: current, or e.g. v1.70.0."
  type        = string
  default     = "current"
}

variable "extra_packages" {
  description = "More packages of the distribution, e.g. [\"htop\", \"tmux\"]."
  type        = list(string)
  default     = []
}
