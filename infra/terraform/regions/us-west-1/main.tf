# Cloak VPN — us-west-1 (Hetzner Hillsboro, Oregon, USA).
#
# Region-specific values are hardcoded here. User/secret values come from
# variables (see variables.tf + terraform.tfvars).
#
# Privacy note: Hetzner Hillsboro is on US soil — full Five Eyes / 14 Eyes
# jurisdiction. Use this region for users who prioritize latency or
# legal-process predictability under US law over avoiding US-jurisdiction
# providers. Surface this in product UI when offering region selection.

module "concentrator" {
  source = "../../modules/concentrator"

  # Region-specific.
  #
  # Note: US Hetzner data centers (ash, hil) only support AMD-based CPX*
  # server types — the Intel-based CX series is EU-only. cpx11 is the
  # closest equivalent to cx22/cx23 for our use case (2 vCPU, 2 GB RAM,
  # 40 GB SSD, ~€4.49/mo). For a low-traffic VPN concentrator with
  # hundreds of peers, 2 GB RAM is plenty — most rosenpass memory is
  # per-active-session and we have wide margin (see docs/IOS_PQC.md
  # memory profile, ~3 MB working set per handshake).
  server_name = "cloak-us-west-1"
  location    = "hil"
  server_type = "cpx11"
  image       = "ubuntu-24.04"

  # Passed through from root.
  ssh_public_key_path = var.ssh_public_key_path
  admin_ip_cidrs      = var.admin_ip_cidrs
  enable_api_port     = var.enable_api_port
}
