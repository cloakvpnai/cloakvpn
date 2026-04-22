# Cloak VPN — fi1 (Finland / Helsinki).
#
# Region-specific values are hardcoded here. User/secret values come from
# variables (see variables.tf + terraform.tfvars).

module "concentrator" {
  source = "../../modules/concentrator"

  # Region-specific.
  server_name = "cloak-fi1"
  location    = "hel1"
  server_type = "cx23"
  image       = "ubuntu-24.04"

  # Passed through from root.
  ssh_public_key_path = var.ssh_public_key_path
  admin_ip_cidrs      = var.admin_ip_cidrs
  enable_api_port     = var.enable_api_port
}
