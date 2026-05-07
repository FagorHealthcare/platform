# =====================================================================
# Outputs — non-sensitive only. Operator copy-pastes these into the
# follow-on docker-compose configs (zot-config.json, loki-config.yaml,
# Caddyfile) and into the SSH command for first login.
# =====================================================================

output "droplet_ipv4" {
  description = "Reserved IPv4 attached to the platform droplet. Use this for DNS, SSH, and any external monitoring."
  value       = digitalocean_reserved_ip.platform.ip_address
}

output "droplet_id" {
  description = "DigitalOcean droplet ID (useful for `doctl compute droplet get <id>`)."
  value       = digitalocean_droplet.platform.id
}

output "spaces_registry_endpoint" {
  description = "S3 endpoint URL for the registry bucket — paste into Zot's storageDriver.regionendpoint."
  value       = "https://${var.region}.digitaloceanspaces.com"
}

output "spaces_registry_bucket" {
  description = "Registry bucket name (Zot storageDriver.bucket)."
  value       = digitalocean_spaces_bucket.registry.name
}

output "spaces_logs_endpoint" {
  description = "S3 endpoint URL for the logs bucket — paste into Loki's common.storage.s3.endpoint."
  value       = "${var.region}.digitaloceanspaces.com"
}

output "spaces_logs_bucket" {
  description = "Logs bucket name (Loki common.storage.s3.bucketnames)."
  value       = digitalocean_spaces_bucket.logs.name
}

output "dns_records" {
  description = "Map of record short-name → fully-qualified domain name. Verify with `dig +short <fqdn>`."
  value = {
    for k, name in local.dns_records :
    k => "${name}.${var.domain}"
  }
}

output "ssh_command" {
  description = "Copy-paste SSH command for the operator. Cloud-init may take ~2 minutes after apply before sshd accepts connections."
  value       = "ssh root@${digitalocean_reserved_ip.platform.ip_address}"
}
