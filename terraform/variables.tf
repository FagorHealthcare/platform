# =====================================================================
# Input variables.
#
# Required variables (no default) MUST be set in `terraform.tfvars` (or
# via -var / TF_VAR_*). Variables with defaults are safe to leave alone
# for a typical fra1 deployment.
# =====================================================================

# ---------- Required: secrets ----------------------------------------

variable "do_token" {
  description = "DigitalOcean API token with Droplet, Reserved IP, Firewall, Domain, SSH key, and Spaces scopes."
  type        = string
  sensitive   = true
}

variable "do_spaces_access_id" {
  description = "DigitalOcean Spaces access key ID (generated under API → Spaces Keys; distinct from the API token above)."
  type        = string
  sensitive   = true
}

variable "do_spaces_secret_key" {
  description = "DigitalOcean Spaces secret access key paired with do_spaces_access_id."
  type        = string
  sensitive   = true
}

# ---------- Required: operator inputs --------------------------------

variable "ssh_public_key" {
  description = "Operator's SSH public key (the full single-line `ssh-ed25519 AAAA…` or `ssh-rsa AAAA…` content) — registered with DO and authorized on the droplet."
  type        = string
}

variable "operator_ssh_source_ips" {
  description = "List of CIDRs allowed to reach port 22 on the droplet (e.g. operator's home + office). Use [\"0.0.0.0/0\"] only if you know what you're doing."
  type        = list(string)
}

variable "letsencrypt_email" {
  description = "Email used by Caddy for ACME registration and by DO firewall as the alert contact. Should be a real, monitored address."
  type        = string
}

# ---------- Defaults: region / sizing --------------------------------

variable "region" {
  description = "DigitalOcean region slug. Both Spaces buckets and the droplet land here."
  type        = string
  default     = "fra1"
}

variable "droplet_size" {
  description = "DigitalOcean droplet size slug. Pillar 06 sizing target."
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "droplet_name" {
  description = "Hostname / DO display name of the platform droplet."
  type        = string
  default     = "md-platform"
}

# ---------- Defaults: DNS --------------------------------------------

variable "domain" {
  description = "Existing DO-managed DNS zone under which records are created. Verify with `doctl compute domain list`."
  type        = string
  default     = "fmd.fagorhealthcare.com"
}

variable "subdomain_label" {
  description = "Sub-label that platform records nest under. Combined with the per-service prefix (e.g. `registry.<label>.<domain>`)."
  type        = string
  default     = "platform"
}

# ---------- Defaults: Spaces -----------------------------------------

variable "spaces_bucket_registry" {
  description = "DO Spaces bucket name backing Zot. Globally unique within the DO Spaces namespace."
  type        = string
  default     = "platform-registry"
}

variable "spaces_bucket_logs" {
  description = "DO Spaces bucket name backing Loki. Globally unique within the DO Spaces namespace."
  type        = string
  default     = "platform-logs"
}

# ---------- Defaults: protective features ----------------------------

variable "enable_droplet_backups" {
  description = "Enable DO weekly snapshots ($0.06/GB-mo). Strongly recommended."
  type        = bool
  default     = true
}

variable "enable_droplet_monitoring" {
  description = "Enable the DO monitoring agent (CPU, memory, disk metrics in DO console). Free."
  type        = bool
  default     = true
}
