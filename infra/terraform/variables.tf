variable "hcloud_token" {
  description = "Hetzner Cloud API token (read+write). Create at https://console.hetzner.cloud → Security → API Tokens."
  type        = string
  sensitive   = true
}

variable "server_name" {
  description = "Hostname of the concentrator. Becomes the Hetzner server label and the PTR record."
  type        = string
  default     = "cloak-fi1"
}

variable "location" {
  description = "Hetzner datacenter location. 'hel1' = Helsinki (recommended: outside 14 Eyes, low EU latency). Alternatives: 'fsn1'/'nbg1' (Germany), 'ash'/'hil' (US), 'sin' (Singapore)."
  type        = string
  default     = "hel1"
}

variable "server_type" {
  description = "CX23 is Hetzner's current small Intel shared-vCPU type (replaces CX22 retired in 2025/26). Roughly 2 vCPU / 4 GB / 40 GB SSD / 20 TB traffic. Upgrade to CX33/CX43 if you outgrow CPU — switch is a reboot. If your chosen location retires CX23, query https://api.hetzner.cloud/v1/server_types for current offerings."
  type        = string
  default     = "cx23"
}

variable "image" {
  description = "OS image. Ubuntu 24.04 is the tested target for server/scripts/setup.sh."
  type        = string
  default     = "ubuntu-24.04"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key that will be authorized for root on the box. Generate with `ssh-keygen -t ed25519 -f ~/.ssh/cloakvpn_ed25519` and pass the `.pub`."
  type        = string
  default     = "~/.ssh/cloakvpn_ed25519.pub"
}

variable "admin_ip_cidrs" {
  description = "CIDRs allowed to SSH to the concentrator. Lock this down to your home/office IP; never leave it open to 0.0.0.0/0 once you're done setting up."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_api_port" {
  description = "Open :443/tcp for the Go API (cloakvpn-api). Keep disabled until you've got Caddy/nginx + a cert provisioned on the box."
  type        = bool
  default     = false
}
