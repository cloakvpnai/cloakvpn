# Module inputs. The Hetzner provider is configured at the root level
# (regions/<slug>/versions.tf), so this module does NOT take an hcloud_token.

variable "server_name" {
  description = "Hostname of the concentrator (becomes the Hetzner label and the DNS prefix, e.g. cloak-fi1 → fi1.cloakvpn.ai)."
  type        = string
}

variable "location" {
  description = "Hetzner datacenter location code. Options: hel1 (Helsinki), fsn1/nbg1 (Germany), ash (Ashburn US-East), hil (Hillsboro US-West), sin (Singapore)."
  type        = string
}

variable "server_type" {
  description = "CX23 is Hetzner's current small Intel shared-vCPU type (~2 vCPU, 4 GB, 40 GB SSD, 20 TB traffic). Upgrade to CX33/CX43 if a region outgrows CPU."
  type        = string
  default     = "cx23"
}

variable "image" {
  description = "OS image. Ubuntu 24.04 is the tested target for server/scripts/setup.sh."
  type        = string
  default     = "ubuntu-24.04"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key authorized for root. Generate with `ssh-keygen -t ed25519 -f ~/.ssh/cloakvpn_ed25519` and pass the `.pub`."
  type        = string
}

variable "admin_ip_cidrs" {
  description = "CIDRs allowed to SSH to this concentrator. Lock down to your admin IP(s); 0.0.0.0/0 is acceptable but noisy."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_api_port" {
  description = "Open :443/tcp for the Go API (cloakvpn-api). Keep false until Caddy/nginx + a cert are provisioned."
  type        = bool
  default     = false
}
