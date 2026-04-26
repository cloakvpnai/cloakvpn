# Re-export module outputs so `terraform output -raw ipv4` works as before.

output "server_name" { value = module.concentrator.server_name }
output "ipv4"        { value = module.concentrator.ipv4 }
output "ipv6"        { value = module.concentrator.ipv6 }
output "ssh"         { value = module.concentrator.ssh }
output "location"    { value = module.concentrator.location }
