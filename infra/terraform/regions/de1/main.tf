# Cloak VPN — de1 (Germany / Nuremberg).
#
# Germany is 14-Eyes — disclose on any page that maps regions to
# jurisdictions. If Germany is a dealbreaker for a customer segment, pair
# with CH/SE/IS when those providers get added.
#
# Note: originally targeted fsn1 (Falkenstein) but Hetzner had that location
# disabled for new CX23 servers at provision time (resource_unavailable),
# so we moved to nbg1. Same country, same jurisdiction, adjacent DC.

module "concentrator" {
  source = "../../modules/concentrator"

  # Region-specific.
  server_name = "cloak-de1"
  location    = "nbg1"
  server_type = "cx23"
  image       = "ubuntu-24.04"

  # Passed through from root.
  ssh_public_key_path = var.ssh_public_key_path
  admin_ip_cidrs      = var.admin_ip_cidrs
  enable_api_port     = var.enable_api_port
}
