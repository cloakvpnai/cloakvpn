# Cloak VPN — concentrator module.
#
# One instance = one VPN region. Each region's root config (regions/<slug>/)
# calls this module with region-specific params (name, location) and
# user-specific params (SSH key path, admin CIDRs).
#
# Creates:
#   - 1× SSH key registered in the Hetzner project (named per-region so
#     multiple regions in one project don't collide)
#   - 1× Firewall (deny-by-default, allow SSH from admin_ip_cidrs,
#                  51820/udp WireGuard worldwide, 9999/udp Rosenpass worldwide,
#                  optional 443/tcp for the Go API)
#   - 1× Server (CX23 by default, Ubuntu 24.04), attached to the firewall

resource "hcloud_ssh_key" "admin" {
  # Suffix with server_name so each region gets its own key resource —
  # Hetzner requires unique names across the project.
  name       = "cloakvpn-admin-${var.server_name}"
  public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
}

resource "hcloud_firewall" "cloak" {
  name = "cloakvpn-fw-${var.server_name}"

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = var.admin_ip_cidrs
    description = "SSH (admin)"
  }

  rule {
    direction   = "in"
    protocol    = "udp"
    port        = "51820"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "WireGuard"
  }

  rule {
    direction   = "in"
    protocol    = "udp"
    port        = "9999"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "Rosenpass PQ handshake"
  }

  # ICMP for reachability diagnostics (ping).
  rule {
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "ICMP"
  }

  dynamic "rule" {
    for_each = var.enable_api_port ? [1] : []
    content {
      direction   = "in"
      protocol    = "tcp"
      port        = "443"
      source_ips  = ["0.0.0.0/0", "::/0"]
      description = "cloakvpn-api (TLS)"
    }
  }
}

resource "hcloud_server" "concentrator" {
  name         = var.server_name
  server_type  = var.server_type
  image        = var.image
  location     = var.location
  ssh_keys     = [hcloud_ssh_key.admin.id]
  firewall_ids = [hcloud_firewall.cloak.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  labels = {
    project = "cloakvpn"
    role    = "concentrator"
    phase   = "0"
    region  = var.server_name
  }

  # Cloud-init: enable unattended security updates + disable password auth.
  # The real provisioning (WireGuard, Rosenpass, UFW, tmpfs /var/log) is done
  # by server/scripts/setup.sh, which deploy.sh uploads and runs over SSH
  # after this server is reachable.
  user_data = <<-CLOUDINIT
    #cloud-config
    package_update: true
    package_upgrade: true
    packages:
      - unattended-upgrades
      - fail2ban
    ssh_pwauth: false
    disable_root: false
    runcmd:
      - [ bash, -c, "echo 'cloakvpn-user-data complete' >> /var/log/cloud-init-cloak.log" ]
  CLOUDINIT
}
