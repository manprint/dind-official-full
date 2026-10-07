terraform {
  # OpenTofu (`tofu`, installed in the image) or Terraform: nothing here is
  # specific to either.
  required_version = ">= 1.6.0"

  required_providers {
    incus = {
      source = "lxc/incus"
      # exec commands since 1.1; tested with the version in .terraform.lock.hcl.
      version = "~> 1.2"
    }
  }
}

# The incus client's configuration and default remote, as for the bash
# templates: inside the Incus container that is the local daemon, through its
# unix socket. Another server: `incus remote add NAME URL` first, then
# remote = "NAME".
provider "incus" {}
