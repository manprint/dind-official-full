# A development instance, as the bash templates create it: limits, nesting for
# Docker, optional fixed address, root disk size and ssh published on the
# Incus host, then the guest provisioning (user, locale, ssh, sudo, Docker,
# rclone, tools). guest/<distro>.sh is the provisioning script of
# create_incus_<distro>.sh, byte for byte (tests/terraform.sh checks it).

locals {
  # Defaults of each template, as in the header of create_incus_<distro>.sh.
  # probe: the mirror the guest must resolve before it is provisioned.
  distros = {
    alpine     = { image = "images:alpine/3.24", user = "alpine", probe = "dl-cdn.alpinelinux.org" }
    debian13   = { image = "images:debian/13", user = "debian", probe = "deb.debian.org" }
    ubuntu2404 = { image = "images:ubuntu/24.04", user = "ubuntu", probe = "archive.ubuntu.com" }
    ubuntu2604 = { image = "images:ubuntu/26.04", user = "ubuntu", probe = "archive.ubuntu.com" }
    fedora     = { image = "images:fedora/44", user = "fedora", probe = "mirrors.fedoraproject.org" }
  }
  distro = local.distros[var.distro]

  name      = var.instance_name != "" ? var.instance_name : "${var.distro}-dev"
  image     = var.instance_image != "" ? var.instance_image : local.distro.image
  user_name = var.user_name != "" ? var.user_name : local.distro.user
  remote    = var.remote != "" ? var.remote : null
  project   = var.project != "" ? var.project : null

  # Incus has no swap size for containers (limits.memory.swap is a bool, and
  # with a memory limit the cgroup gets 0): the size goes into raw.lxc as
  # memory.swap.max in bytes, a zero size turns swap off.
  swap_units = {
    ""  = 1
    B   = 1
    K   = 1024
    KiB = 1024
    kB  = 1000
    KB  = 1000
    M   = 1048576
    MiB = 1048576
    MB  = 1000000
    G   = 1073741824
    GiB = 1073741824
    GB  = 1000000000
    T   = 1099511627776
    TiB = 1099511627776
    TB  = 1000000000000
  }
  swap_words = ["0", "off", "none", "no"]
  swap_size  = var.instance_swap == "" || contains(local.swap_words, var.instance_swap) ? null : regex("^([0-9]+)[[:space:]]*([A-Za-z]*)$", var.instance_swap)
  swap_bytes = local.swap_size == null ? null : tonumber(local.swap_size[0]) * local.swap_units[local.swap_size[1]]
  swap_off   = contains(local.swap_words, var.instance_swap) || local.swap_bytes == 0

  # The order of the bash templates' `incus launch -c`: instance_config comes
  # last and wins.
  config = merge(
    { for k, v in {
      "limits.memory"                        = var.instance_memory != "" ? var.instance_memory : null
      "limits.cpu"                           = var.instance_cpu != "" ? var.instance_cpu : null
      "limits.memory.swap"                   = local.swap_off ? "false" : null
      "raw.lxc"                              = local.swap_bytes != null && !local.swap_off ? "lxc.cgroup2.memory.swap.max = ${format("%d", local.swap_bytes)}" : null
      "security.nesting"                     = tostring(var.instance_nesting)
      "boot.autostart"                       = tostring(var.instance_autostart)
      "security.privileged"                  = var.instance_privileged ? "true" : null
      "security.syscalls.intercept.mknod"    = var.instance_intercept ? "true" : null
      "security.syscalls.intercept.setxattr" = var.instance_intercept ? "true" : null
      "security.syscalls.intercept.sysinfo"  = var.instance_intercept ? "true" : null
    } : k => v if v != null },
    var.instance_config,
  )

  # A device of the instance replaces the profiles' device of the same name
  # whole, so an override starts from the profiles' one, like `incus launch -d`:
  # the last profile that defines the device wins.
  profile_devices = merge([for p in var.instance_profiles : { for d in data.incus_profile.this[p].device : d.name => d }]...)
  profile_root    = try(local.profile_devices["root"].properties, {})
  profile_eth0    = try(local.profile_devices["eth0"].properties, null)

  # instance_storage_pool is `incus launch -s`: a root disk of its own on that
  # pool, nothing inherited.
  root_device = var.instance_storage_pool == "" && var.instance_disk_size == "" ? null : {
    type = "disk"
    properties = merge(
      { for k, v in local.profile_root : k => v if var.instance_storage_pool == "" },
      { path = "/" },
      { for k, v in { pool = var.instance_storage_pool, size = var.instance_disk_size } : k => v if v != "" },
    )
  }
  # instance_network is `incus launch -n` (a managed network): eth0 on it.
  eth0_device = var.instance_network == "" && var.instance_ipv4 == "" ? null : {
    type = "nic"
    properties = merge(
      { for k, v in coalesce(local.profile_eth0, {}) : k => v if var.instance_network == "" },
      { for k, v in { name = "eth0", network = var.instance_network } : k => v if var.instance_network != "" },
      { for k, v in { "ipv4.address" = var.instance_ipv4 } : k => v if v != "" },
    )
  }
  ssh_device = var.instance_ssh_publish_port == null ? null : {
    type = "proxy"
    properties = {
      listen  = "tcp:0.0.0.0:${var.instance_ssh_publish_port}"
      connect = "tcp:127.0.0.1:22"
    }
  }
  devices = merge(
    { for k, v in { root = local.root_device, eth0 = local.eth0_device, ssh = local.ssh_device } : k => v if v != null },
    var.instance_devices,
  )

  # What create_incus_<distro>.sh passes to its provisioning script.
  guest_script = file("${path.module}/guest/${var.distro}.sh")
  guest_env = merge(
    {
      INSTANCE_NAME       = local.name
      USER_NAME           = local.user_name
      USER_UID            = tostring(var.user_uid)
      USER_PASSWORD       = var.user_password
      USER_SHELL          = var.user_shell
      USER_SUDO           = tostring(var.user_sudo)
      USER_SUDO_NOPASSWD  = tostring(var.user_sudo_nopasswd)
      TIMEZONE            = var.timezone
      LOCALE              = var.locale
      KEYMAP              = var.keymap
      SSH_PASSWORD_AUTH   = var.ssh_password_auth
      SSH_PERMIT_ROOT     = var.ssh_permit_root
      INSTALL_DOCKER      = tostring(var.install_docker)
      DOCKER_LOG_MAX_SIZE = var.docker_log_max_size
      DOCKER_LOG_MAX_FILE = tostring(var.docker_log_max_file)
      INSTALL_NET_TOOLS   = tostring(var.install_net_tools)
      INSTALL_RCLONE      = tostring(var.install_rclone)
      RCLONE_RELEASE      = var.rclone_release
      EXTRA_PACKAGES      = join(" ", var.extra_packages)
    },
    # Alpine only has its own Docker packages.
    { for k, v in { DOCKER_SOURCE = var.docker_source } : k => v if var.distro != "alpine" },
  )

  # The network comes up a few seconds after the start: the provisioning needs
  # the distro's mirror.
  wait_network = <<-EOT
    i=0
    until getent hosts ${local.distro.probe} >/dev/null 2>&1; do
      i=$((i + 1))
      if [ "$i" -ge ${var.wait_network_seconds} ]; then
        echo "no working network or DNS: ${local.distro.probe} does not resolve after ${var.wait_network_seconds}s" >&2
        exit 1
      fi
      sleep 1
    done
  EOT

  # Run once, when the instance is created, in key order. The script is passed
  # inline: nothing is left in the guest.
  exec = { for k, v in {
    "10-wait-network" = var.wait_network_seconds == 0 ? null : {
      command     = ["/bin/sh", "-c", local.wait_network]
      environment = null
      timeout     = null
      trigger     = "once"
    }
    "20-provision" = !var.provision ? null : {
      command     = ["/bin/sh", "-c", local.guest_script]
      environment = local.guest_env
      timeout     = var.provision_timeout
      trigger     = "once"
    }
  } : k => v if v != null }
}

data "incus_profile" "this" {
  for_each = toset(var.instance_profiles)

  name    = each.key
  remote  = local.remote
  project = local.project
}

# The provisioning only runs when the instance is created, so what it used is
# kept here: a change replaces the instance (the plan says so) instead of being
# silently ignored. The password is part of it, hence a hash.
resource "terraform_data" "guest" {
  input = var.provision ? sha256(jsonencode([local.guest_script, local.guest_env])) : "none"
}

resource "incus_instance" "this" {
  name     = local.name
  image    = local.image
  remote   = local.remote
  project  = local.project
  profiles = var.instance_profiles
  config   = local.config

  dynamic "device" {
    for_each = local.devices
    content {
      name       = device.key
      type       = device.value.type
      properties = device.value.properties
    }
  }

  exec = length(local.exec) > 0 ? local.exec : null

  lifecycle {
    replace_triggered_by = [terraform_data.guest]

    # /opt/incus-template is in the container's writable layer: a state kept
    # there is lost when the container is recreated, and the instance it
    # describes is left behind.
    precondition {
      condition     = !startswith(abspath(path.root), "/opt/incus-template/")
      error_message = "Copy the template under your home first and run it there (cp -r /opt/incus-template/terraform ~/incus-dev): a state kept in /opt/incus-template is lost when the container is recreated."
    }

    precondition {
      condition     = try(local.root_device.properties.pool, "") != "" || local.root_device == null
      error_message = "The root disk needs a storage pool: the profiles define no root disk, set instance_storage_pool."
    }

    precondition {
      condition     = var.instance_ipv4 == "" || var.instance_network != "" || local.profile_eth0 != null
      error_message = "instance_ipv4 needs an eth0: the profiles define none, set instance_network."
    }
  }
}
