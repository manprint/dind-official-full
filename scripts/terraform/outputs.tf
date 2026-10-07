# What create_incus_<distro>.sh prints on its closing "ready:" line. The
# addresses are the ones Incus reported at the end of the apply; `tofu refresh`
# reads them again (an instance created with wait_network_seconds = 0 may not
# have one yet).

output "name" {
  description = "Instance name."
  value       = incus_instance.this.name
}

output "ipv4" {
  description = "IPv4 address of the instance, empty while it has none."
  value       = incus_instance.this.ipv4_address == null ? "" : incus_instance.this.ipv4_address
}

output "ipv6" {
  description = "IPv6 address of the instance, empty while it has none."
  value       = incus_instance.this.ipv6_address == null ? "" : incus_instance.this.ipv6_address
}

output "user" {
  description = "User created by the provisioning."
  value       = var.provision ? local.user_name : null
}

output "ssh" {
  description = "How to log in."
  value = !var.provision ? null : join("   ", compact([
    "ssh ${local.user_name}@${coalesce(incus_instance.this.ipv4_address, "<ip>")}",
    var.instance_ssh_publish_port == null ? "" : "(or port ${var.instance_ssh_publish_port} of the incus host)",
  ]))
}

output "user_password" {
  description = "Password of the user: tofu output -raw user_password."
  value       = var.provision ? var.user_password : null
  sensitive   = true
}
