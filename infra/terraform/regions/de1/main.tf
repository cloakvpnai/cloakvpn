# Cloak VPN — de1 (Germany / Falkenstein).
#
# Hetzner's flagship DC. Note: Germany is 14-Eyes — disclose on any page
# that maps regions to jurisdictions. If Germany is a dealbreaker for a
# customer segment, pair with CH/SE/IS when those providers get added.

module "concentrator" {
  source = "../../modules/concentrator"

  # Region-specific.
  server_name = "cloak-de1"
  location    = "fsn1"
  server_type = "cx23"
  image       = "ubuntu-24.04"

  # Passed through from root.
  ssh_public_key_path = var.ssh_public_key_path
  admin_ip_cidrs      = var.admin_ip_cidrs
  enable_api_port     = var.enable_api_port
}
