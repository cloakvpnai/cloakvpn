output "server_name" {
  value       = hcloud_server.concentrator.name
  description = "Hetzner server name."
}

output "ipv4" {
  value       = hcloud_server.concentrator.ipv4_address
  description = "Public IPv4 address. Point cloakvpn.ai / fi1.cloakvpn.ai A record at this."
}

output "ipv6" {
  value       = hcloud_server.concentrator.ipv6_address
  description = "Public IPv6 address. Point cloakvpn.ai / fi1.cloakvpn.ai AAAA record at this."
}

output "ssh" {
  value       = "ssh root@${hcloud_server.concentrator.ipv4_address}"
  description = "Shortcut SSH command."
}

output "location" {
  value       = hcloud_server.concentrator.location
  description = "Resolved datacenter (city + country)."
}
