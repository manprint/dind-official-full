# Every variable at its default, for tofu test only: loaded over TF_VAR_* and
# over the tfvars files next to main.tf, so the unit tests do not depend on how
# this copy is configured. Generated from variables.tf (in the image's
# repository: tests/terraform.sh --fix).
distro                    = "debian13"
remote                    = ""
project                   = ""
instance_name             = ""
instance_image            = ""
instance_profiles         = ["default"]
instance_storage_pool     = ""
instance_network          = ""
instance_ipv4             = ""
instance_memory           = "2GiB"
instance_cpu              = "2"
instance_swap             = ""
instance_disk_size        = ""
instance_nesting          = true
instance_intercept        = true
instance_privileged       = false
instance_autostart        = true
instance_config           = {}
instance_devices          = {}
instance_ssh_publish_port = null
wait_network_seconds      = 90
provision                 = true
provision_timeout         = "30m"
user_name                 = ""
user_uid                  = 1000
user_password             = "password"
user_shell                = "/bin/bash"
user_sudo                 = true
user_sudo_nopasswd        = false
timezone                  = "Europe/Rome"
locale                    = "it_IT.UTF-8"
keymap                    = "it"
ssh_password_auth         = "yes"
ssh_permit_root           = "no"
install_docker            = true
docker_source             = "official"
docker_log_max_size       = "10m"
docker_log_max_file       = 5
install_net_tools         = true
install_rclone            = true
rclone_release            = "current"
extra_packages            = []
