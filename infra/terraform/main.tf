# Cloak VPN — Phase 0 concentrator (Hetzner CX22, Helsinki by default).
#
# What this creates:
#   - 1× SSH key registered in the Hetzner project
#   - 1× Firewall (deny-by-default, allow SSH from admin_ip_cidrs,
#                  51820/udp WireGuard worldwide, 9999/udp Rosenpass worldwide,
#                  optional 443/tcp for the Go API)
#   - 1× Server (CX22, Ubuntu 24.04), attached to the firewall
#
# What this does NOT do (intentionally):
#   - DNS: point cloakvpn.ai / api.cloakvpn.ai at the server's IPv4/IPv6 in
#     Cloudflare after apply — see `terraform output`.
#   - Bootstrap: the server comes up vanilla. `infra/deploy.sh` rsyncs the
#     repo's server/ dir and runs setup.sh via SSH.

resource "hcloud_ssh_key" "admin" {
  name       = "cloakvpn-admin"
  public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
}

resource "hcloud_firewall" "cloak" {
  name = "cloakvpn-fw"

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "22"
    source_ips = var.admin_ip_cidrs
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
  }

  # Cloud-init: enable unattended security updates + disable password auth.
  # The real provisioning (WireGuard, Rosenpass, firewall rules inside the VM,
  # tmpfs /var/log) is done by server/scripts/setup.sh, which deploy.sh
  # uploads and runs over SSH after this server is reachable.
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
