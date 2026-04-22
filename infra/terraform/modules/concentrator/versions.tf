# Module-level required_providers. The actual provider block (with token)
# is configured at the root level (regions/<slug>/versions.tf) and passed
# implicitly to this module.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.48"
    }
  }
}
