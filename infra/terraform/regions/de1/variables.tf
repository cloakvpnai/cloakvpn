# Same root variable shape as every region. Keeps tfvars portable between regions.

variable "hcloud_token" {
  description = "Hetzner Cloud API token (read+write)."
  type        = string
  sensitive   = true
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key authorized for root on this concentrator."
  type        = string
  default     = "~/.ssh/cloakvpn_ed25519.pub"
}

variable "admin_ip_cidrs" {
  description = "CIDRs allowed to SSH to this concentrator."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_api_port" {
  description = "Open :443/tcp for the Go API on this concentrator."
  type        = bool
  default     = false
}
