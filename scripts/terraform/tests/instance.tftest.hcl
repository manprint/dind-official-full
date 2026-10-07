# tofu test: what the template asks Incus for, against a mocked provider (no
# daemon needed). OpenTofu cannot mock the profiles' devices (a computed block),
# so here the profiles define none: inheriting the profile's root disk or eth0
# is covered by tests/smoke.incus.sh and tests/templates.sh on a real daemon.

mock_provider "incus" {}

run "defaults" {
  command = plan

  assert {
    condition     = incus_instance.this.name == "debian13-dev" && incus_instance.this.image == "images:debian/13"
    error_message = "default name or image"
  }

  assert {
    condition     = incus_instance.this.profiles == tolist(["default"]) && incus_instance.this.remote == null && incus_instance.this.project == null
    error_message = "default profiles, remote or project"
  }

  assert {
    condition = incus_instance.this.config == tomap({
      "limits.memory"                        = "2GiB"
      "limits.cpu"                           = "2"
      "security.nesting"                     = "true"
      "boot.autostart"                       = "true"
      "security.syscalls.intercept.mknod"    = "true"
      "security.syscalls.intercept.setxattr" = "true"
      "security.syscalls.intercept.sysinfo"  = "true"
    })
    error_message = "default config: ${jsonencode(incus_instance.this.config)}"
  }

  assert {
    condition     = length(incus_instance.this.device) == 0
    error_message = "no device by default: the profiles' ones are used"
  }
}

run "distro_defaults" {
  command = plan

  variables {
    distro = "fedora"
  }

  assert {
    condition     = incus_instance.this.name == "fedora-dev" && incus_instance.this.image == "images:fedora/44"
    error_message = "fedora name or image"
  }
}

run "instance_settings" {
  command = plan

  variables {
    distro            = "alpine"
    instance_name     = "web"
    instance_image    = "images:alpine/edge"
    instance_profiles = ["default", "extra"]
    remote            = "lab"
    project           = "dev"
  }

  assert {
    condition     = incus_instance.this.name == "web" && incus_instance.this.image == "images:alpine/edge"
    error_message = "name or image not taken"
  }

  assert {
    condition     = incus_instance.this.profiles == tolist(["default", "extra"])
    error_message = "profiles order"
  }

  assert {
    condition     = incus_instance.this.remote == "lab" && incus_instance.this.project == "dev"
    error_message = "remote or project not taken"
  }

  assert {
    condition     = data.incus_profile.this["extra"].remote == "lab" && data.incus_profile.this["extra"].project == "dev"
    error_message = "profiles read from another remote or project"
  }
}

run "no_limits" {
  command = plan

  variables {
    instance_memory = ""
    instance_cpu    = ""
  }

  assert {
    condition     = !contains(keys(incus_instance.this.config), "limits.memory") && !contains(keys(incus_instance.this.config), "limits.cpu")
    error_message = "an empty limit must leave the key out"
  }
}

run "flags" {
  command = plan

  variables {
    instance_nesting    = false
    instance_autostart  = false
    instance_privileged = true
    instance_intercept  = false
  }

  assert {
    condition = incus_instance.this.config == tomap({
      "limits.memory"       = "2GiB"
      "limits.cpu"          = "2"
      "security.nesting"    = "false"
      "boot.autostart"      = "false"
      "security.privileged" = "true"
    })
    error_message = "flags: ${jsonencode(incus_instance.this.config)}"
  }
}

run "instance_config_wins" {
  command = plan

  variables {
    instance_config = {
      "limits.processes" = "500"
      "security.nesting" = "false"
    }
  }

  assert {
    condition     = incus_instance.this.config["limits.processes"] == "500" && incus_instance.this.config["security.nesting"] == "false"
    error_message = "instance_config must be applied last"
  }
}

# ---- swap ----------------------------------------------------------------------

run "swap_default" {
  command = plan

  assert {
    condition     = !contains(keys(incus_instance.this.config), "raw.lxc") && !contains(keys(incus_instance.this.config), "limits.memory.swap")
    error_message = "no swap setting by default"
  }
}

run "swap_gib" {
  command = plan

  variables {
    instance_swap = "1GiB"
  }

  assert {
    condition     = incus_instance.this.config["raw.lxc"] == "lxc.cgroup2.memory.swap.max = 1073741824"
    error_message = "1GiB: ${incus_instance.this.config["raw.lxc"]}"
  }

  assert {
    condition     = !contains(keys(incus_instance.this.config), "limits.memory.swap")
    error_message = "a swap size must not turn swap off"
  }
}

run "swap_space_and_mib" {
  command = plan

  variables {
    instance_swap = "512 MiB"
  }

  assert {
    condition     = incus_instance.this.config["raw.lxc"] == "lxc.cgroup2.memory.swap.max = 536870912"
    error_message = "512 MiB: ${incus_instance.this.config["raw.lxc"]}"
  }
}

run "swap_decimal_units" {
  command = plan

  variables {
    instance_swap = "1500kB"
  }

  assert {
    condition     = incus_instance.this.config["raw.lxc"] == "lxc.cgroup2.memory.swap.max = 1500000"
    error_message = "1500kB: ${incus_instance.this.config["raw.lxc"]}"
  }
}

run "swap_k_is_binary" {
  command = plan

  variables {
    instance_swap = "4K"
  }

  assert {
    condition     = incus_instance.this.config["raw.lxc"] == "lxc.cgroup2.memory.swap.max = 4096"
    error_message = "4K: ${incus_instance.this.config["raw.lxc"]}"
  }
}

run "swap_megabyte" {
  command = plan

  variables {
    instance_swap = "3MB"
  }

  assert {
    condition     = incus_instance.this.config["raw.lxc"] == "lxc.cgroup2.memory.swap.max = 3000000"
    error_message = "3MB: ${incus_instance.this.config["raw.lxc"]}"
  }
}

run "swap_tebibyte" {
  command = plan

  variables {
    instance_swap = "2TiB"
  }

  assert {
    condition     = incus_instance.this.config["raw.lxc"] == "lxc.cgroup2.memory.swap.max = 2199023255552"
    error_message = "2TiB, no exponent notation: ${incus_instance.this.config["raw.lxc"]}"
  }
}

run "swap_bytes" {
  command = plan

  variables {
    instance_swap = "1048576"
  }

  assert {
    condition     = incus_instance.this.config["raw.lxc"] == "lxc.cgroup2.memory.swap.max = 1048576"
    error_message = "a bare number is bytes"
  }
}

run "swap_off" {
  command = plan

  variables {
    instance_swap = "off"
  }

  assert {
    condition     = incus_instance.this.config["limits.memory.swap"] == "false" && !contains(keys(incus_instance.this.config), "raw.lxc")
    error_message = "off: ${jsonencode(incus_instance.this.config)}"
  }
}

run "swap_zero_size" {
  command = plan

  variables {
    instance_swap = "0GiB"
  }

  assert {
    condition     = incus_instance.this.config["limits.memory.swap"] == "false" && !contains(keys(incus_instance.this.config), "raw.lxc")
    error_message = "0GiB is no swap"
  }
}

run "swap_not_a_size" {
  command = plan

  variables {
    instance_swap = "1.5GiB"
  }

  expect_failures = [var.instance_swap]
}

run "swap_lowercase_unit" {
  command = plan

  variables {
    instance_swap = "1gib"
  }

  expect_failures = [var.instance_swap]
}

# ---- devices -------------------------------------------------------------------

run "pool_and_disk_size" {
  command = plan

  variables {
    instance_storage_pool = "fast"
    instance_disk_size    = "20GiB"
  }

  assert {
    condition     = { for d in incus_instance.this.device : d.name => d.properties }["root"] == tomap({ path = "/", pool = "fast", size = "20GiB" })
    error_message = "root disk on the pool, with its size"
  }
}

run "pool_only" {
  command = plan

  variables {
    instance_storage_pool = "fast"
  }

  assert {
    condition     = { for d in incus_instance.this.device : d.name => d.properties }["root"] == tomap({ path = "/", pool = "fast" })
    error_message = "root disk on the pool"
  }
}

run "disk_size_without_any_pool" {
  command = plan

  variables {
    instance_disk_size = "20GiB"
  }

  # The mocked profiles have no root disk.
  expect_failures = [incus_instance.this]
}

run "network_and_ipv4" {
  command = plan

  variables {
    instance_network = "devnet"
    instance_ipv4    = "10.10.200.50"
  }

  assert {
    condition     = { for d in incus_instance.this.device : d.name => d }["eth0"].type == "nic"
    error_message = "eth0 is a nic"
  }

  assert {
    condition     = { for d in incus_instance.this.device : d.name => d.properties }["eth0"] == tomap({ name = "eth0", network = "devnet", "ipv4.address" = "10.10.200.50" })
    error_message = "eth0 on the network, with its address"
  }
}

run "ipv4_without_any_eth0" {
  command = plan

  variables {
    instance_ipv4 = "10.10.200.50"
  }

  # The mocked profiles have no eth0.
  expect_failures = [incus_instance.this]
}

run "ipv4_not_an_address" {
  command = plan

  variables {
    instance_ipv4 = "10.10.200.256"
  }

  expect_failures = [var.instance_ipv4]
}

run "ipv4_with_prefix" {
  command = plan

  variables {
    instance_ipv4 = "10.10.200.50/24"
  }

  expect_failures = [var.instance_ipv4]
}

run "ssh_published" {
  command = plan

  variables {
    instance_ssh_publish_port = 2222
  }

  assert {
    condition     = { for d in incus_instance.this.device : d.name => d.properties }["ssh"] == tomap({ listen = "tcp:0.0.0.0:2222", connect = "tcp:127.0.0.1:22" })
    error_message = "ssh proxy device"
  }
}

run "ssh_port_out_of_range" {
  command = plan

  variables {
    instance_ssh_publish_port = 70000
  }

  expect_failures = [var.instance_ssh_publish_port]
}

run "ssh_port_not_integer" {
  command = plan

  variables {
    instance_ssh_publish_port = 22.5
  }

  expect_failures = [var.instance_ssh_publish_port]
}

run "more_devices" {
  command = plan

  variables {
    instance_ssh_publish_port = 2222
    instance_devices = {
      data = { type = "disk", properties = { source = "/srv/data", path = "/data" } }
      ssh  = { type = "proxy", properties = { listen = "tcp:127.0.0.1:2200", connect = "tcp:127.0.0.1:22" } }
    }
  }

  assert {
    condition     = { for d in incus_instance.this.device : d.name => d.properties }["data"] == tomap({ source = "/srv/data", path = "/data" })
    error_message = "extra device"
  }

  assert {
    condition     = { for d in incus_instance.this.device : d.name => d.properties }["ssh"]["listen"] == "tcp:127.0.0.1:2200"
    error_message = "instance_devices must replace the template's device of the same name"
  }
}

# ---- names -----------------------------------------------------------------------

run "bad_distro" {
  command = plan

  variables {
    distro = "centos"
  }

  expect_failures = [var.distro]
}

run "name_starting_with_a_digit" {
  command = plan

  variables {
    instance_name = "1web"
  }

  expect_failures = [var.instance_name]
}

run "name_ending_with_a_dash" {
  command = plan

  variables {
    instance_name = "web-"
  }

  expect_failures = [var.instance_name]
}

run "name_with_underscore" {
  command = plan

  variables {
    instance_name = "my_web"
  }

  expect_failures = [var.instance_name]
}
