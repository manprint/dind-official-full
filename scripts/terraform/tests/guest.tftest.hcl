# tofu test: the guest provisioning (what create_incus_<distro>.sh passes to its
# script) and the outputs, against a mocked provider.

mock_provider "incus" {}

run "defaults" {
  command = plan

  assert {
    condition     = keys(incus_instance.this.exec) == tolist(["10-wait-network", "20-provision"])
    error_message = "wait for the network, then provision"
  }

  assert {
    condition     = incus_instance.this.exec["10-wait-network"].trigger == "once" && incus_instance.this.exec["20-provision"].trigger == "once"
    error_message = "the provisioning must only run when the instance is created"
  }

  assert {
    condition     = incus_instance.this.exec["20-provision"].command == tolist(["/bin/sh", "-c", file("${path.module}/guest/debian13.sh")])
    error_message = "the distro's guest script, inline"
  }

  assert {
    condition     = incus_instance.this.exec["20-provision"].timeout == "30m"
    error_message = "default provisioning timeout"
  }

  assert {
    condition     = strcontains(incus_instance.this.exec["10-wait-network"].command[2], "getent hosts deb.debian.org") && strcontains(incus_instance.this.exec["10-wait-network"].command[2], "-ge 90 ]")
    error_message = "wait for the distro's mirror, 90s"
  }

  assert {
    condition = nonsensitive(tomap(merge(incus_instance.this.exec["20-provision"].environment, { USER_PASSWORD = "" }))) == tomap({
      INSTANCE_NAME       = "debian13-dev"
      USER_NAME           = "debian"
      USER_UID            = "1000"
      USER_PASSWORD       = ""
      USER_SHELL          = "/bin/bash"
      USER_SUDO           = "true"
      USER_SUDO_NOPASSWD  = "false"
      TIMEZONE            = "Europe/Rome"
      LOCALE              = "it_IT.UTF-8"
      KEYMAP              = "it"
      SSH_PASSWORD_AUTH   = "yes"
      SSH_PERMIT_ROOT     = "no"
      INSTALL_DOCKER      = "true"
      DOCKER_SOURCE       = "official"
      DOCKER_LOG_MAX_SIZE = "10m"
      DOCKER_LOG_MAX_FILE = "5"
      INSTALL_NET_TOOLS   = "true"
      INSTALL_RCLONE      = "true"
      RCLONE_RELEASE      = "current"
      EXTRA_PACKAGES      = ""
    })
    error_message = "default guest environment"
  }

  assert {
    condition     = incus_instance.this.exec["20-provision"].environment["USER_PASSWORD"] == "password"
    error_message = "default password"
  }

  assert {
    condition     = output.user == "debian"
    error_message = "user output"
  }
}

run "alpine" {
  command = plan

  variables {
    distro = "alpine"
  }

  assert {
    condition     = incus_instance.this.exec["20-provision"].command[2] == file("${path.module}/guest/alpine.sh")
    error_message = "alpine's guest script"
  }

  assert {
    condition     = !contains(keys(incus_instance.this.exec["20-provision"].environment), "DOCKER_SOURCE")
    error_message = "alpine's script has no DOCKER_SOURCE"
  }

  assert {
    condition     = incus_instance.this.exec["20-provision"].environment["USER_NAME"] == "alpine" && strcontains(incus_instance.this.exec["10-wait-network"].command[2], "dl-cdn.alpinelinux.org")
    error_message = "alpine's user and mirror"
  }
}

run "ubuntu2404" {
  command = plan

  variables {
    distro = "ubuntu2404"
  }

  assert {
    condition     = incus_instance.this.image == "images:ubuntu/24.04" && incus_instance.this.exec["20-provision"].command[2] == file("${path.module}/guest/ubuntu2404.sh")
    error_message = "ubuntu 24.04's image and script"
  }

  assert {
    condition     = incus_instance.this.exec["20-provision"].environment["USER_NAME"] == "ubuntu" && strcontains(incus_instance.this.exec["10-wait-network"].command[2], "archive.ubuntu.com")
    error_message = "ubuntu's user and mirror"
  }
}

run "ubuntu2604" {
  command = plan

  variables {
    distro = "ubuntu2604"
  }

  assert {
    condition     = incus_instance.this.image == "images:ubuntu/26.04" && incus_instance.this.exec["20-provision"].command[2] == file("${path.module}/guest/ubuntu2604.sh")
    error_message = "ubuntu 26.04's image and script"
  }
}

run "fedora" {
  command = plan

  variables {
    distro = "fedora"
  }

  assert {
    condition     = incus_instance.this.exec["20-provision"].command[2] == file("${path.module}/guest/fedora.sh")
    error_message = "fedora's script"
  }

  assert {
    condition     = incus_instance.this.exec["20-provision"].environment["USER_NAME"] == "fedora" && strcontains(incus_instance.this.exec["10-wait-network"].command[2], "mirrors.fedoraproject.org")
    error_message = "fedora's user and mirror"
  }
}

run "guest_settings" {
  command = plan

  variables {
    distro              = "ubuntu2604"
    instance_name       = "box"
    user_name           = "dev"
    user_uid            = 2000
    user_password       = "s3cret"
    user_sudo_nopasswd  = true
    install_docker      = false
    docker_source       = "distro"
    docker_log_max_file = 3
    extra_packages      = ["htop", "tmux"]
    provision_timeout   = "1h"
  }

  assert {
    condition = (
      incus_instance.this.exec["20-provision"].environment["INSTANCE_NAME"] == "box" &&
      incus_instance.this.exec["20-provision"].environment["USER_NAME"] == "dev" &&
      incus_instance.this.exec["20-provision"].environment["USER_UID"] == "2000" &&
      incus_instance.this.exec["20-provision"].environment["USER_SUDO_NOPASSWD"] == "true" &&
      incus_instance.this.exec["20-provision"].environment["INSTALL_DOCKER"] == "false" &&
      incus_instance.this.exec["20-provision"].environment["DOCKER_SOURCE"] == "distro" &&
      incus_instance.this.exec["20-provision"].environment["DOCKER_LOG_MAX_FILE"] == "3" &&
      incus_instance.this.exec["20-provision"].environment["EXTRA_PACKAGES"] == "htop tmux"
    )
    error_message = "guest settings not passed to the script"
  }

  assert {
    condition     = incus_instance.this.exec["20-provision"].environment["USER_PASSWORD"] == "s3cret"
    error_message = "password not passed to the script"
  }

  assert {
    condition     = incus_instance.this.exec["20-provision"].timeout == "1h"
    error_message = "provisioning timeout"
  }
}

run "no_provisioning" {
  command = plan

  variables {
    provision = false
  }

  assert {
    condition     = keys(incus_instance.this.exec) == tolist(["10-wait-network"])
    error_message = "only the network wait"
  }

  assert {
    condition     = terraform_data.guest.input == "none"
    error_message = "nothing to replace the instance for"
  }

  assert {
    condition     = output.user == null
    error_message = "no user without the provisioning"
  }
}

run "nothing_to_run" {
  command = plan

  variables {
    provision            = false
    wait_network_seconds = 0
  }

  assert {
    condition     = incus_instance.this.exec == null
    error_message = "no exec at all"
  }
}

run "no_network_wait" {
  command = plan

  variables {
    wait_network_seconds = 0
  }

  assert {
    condition     = keys(incus_instance.this.exec) == tolist(["20-provision"])
    error_message = "only the provisioning"
  }
}

# The provisioning only runs at creation: what it used is tracked, so that a
# change replaces the instance instead of being ignored (checked on a real
# daemon by tests/templates.sh). Here: the settings that do not touch the guest
# must leave the tracked value alone, or every limit change would replace it.
run "first" {
  variables {
    instance_name = "tracked"
  }

  assert {
    condition     = output.name == "tracked" && output.user == "debian"
    error_message = "outputs after apply"
  }

  assert {
    condition     = output.ssh == "ssh debian@${incus_instance.this.ipv4_address}"
    error_message = "ssh output: ${output.ssh}"
  }

  assert {
    condition     = output.user_password == "password"
    error_message = "password output"
  }
}

run "limit_change_keeps_the_guest" {
  command = plan

  variables {
    instance_name             = "tracked"
    instance_memory           = "4GiB"
    instance_cpu              = "4"
    instance_swap             = "1GiB"
    instance_ssh_publish_port = 2222
    provision_timeout         = "2h"
    wait_network_seconds      = 30
  }

  # Unknown, and so a failure, if the change planned a new guest.
  assert {
    condition     = terraform_data.guest.output == terraform_data.guest.input
    error_message = "limits, devices, timeouts and the network wait must not replace the instance"
  }
}

run "ssh_output_with_published_port" {
  variables {
    instance_name             = "tracked"
    instance_ssh_publish_port = 2222
  }

  assert {
    condition     = output.ssh == "ssh debian@${incus_instance.this.ipv4_address}   (or port 2222 of the incus host)"
    error_message = "ssh output: ${output.ssh}"
  }
}

# ---- validation --------------------------------------------------------------------

run "root_user" {
  command = plan

  variables {
    user_name = "root"
  }

  expect_failures = [var.user_name]
}

run "uid_zero" {
  command = plan

  variables {
    user_uid = 0
  }

  expect_failures = [var.user_uid]
}

run "empty_password" {
  command = plan

  variables {
    user_password = ""
  }

  expect_failures = [var.user_password]
}

run "ssh_password_auth_value" {
  command = plan

  variables {
    ssh_password_auth = "maybe"
  }

  expect_failures = [var.ssh_password_auth]
}

run "ssh_permit_root_value" {
  command = plan

  variables {
    ssh_permit_root = "always"
  }

  expect_failures = [var.ssh_permit_root]
}

run "docker_source_value" {
  command = plan

  variables {
    docker_source = "snap"
  }

  expect_failures = [var.docker_source]
}

run "timeout_value" {
  command = plan

  variables {
    provision_timeout = "30 minutes"
  }

  expect_failures = [var.provision_timeout]
}

run "negative_wait" {
  command = plan

  variables {
    wait_network_seconds = -1
  }

  expect_failures = [var.wait_network_seconds]
}
