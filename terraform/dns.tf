# =====================================================================
# DNS records under the existing `fmd.fagorhealthcare.com` zone.
#
# Assumes that zone is already managed by this DigitalOcean account.
# Verify before first apply:
#
#     doctl compute domain list | grep fmd.fagorhealthcare.com
#
# If the zone is missing, create it (or delegate to DO from the parent
# registrar) before running `terraform apply`. We deliberately do NOT
# manage the zone itself here — applying ownership of an existing,
# populated zone would risk wiping unrelated records.
#
# Records produced (all type A, all → reserved IP):
#   platform.fmd.fagorhealthcare.com                 (Portal apex — unified
#                                                     health view: cluster
#                                                     services + platform
#                                                     services + alerts)
#   registry.platform.fmd.fagorhealthcare.com
#   logs.platform.fmd.fagorhealthcare.com
#   alerts.platform.fmd.fagorhealthcare.com          (Alertmanager UI)
#   dashboards.platform.fmd.fagorhealthcare.com      (Perses)
#   dex.platform.fmd.fagorhealthcare.com             (Dex OIDC broker —
#                                                     fronts GitHub for
#                                                     Zot's browser login;
#                                                     see docs/observability-AUTH.md)
# =====================================================================

locals {
  dns_records = {
    # Apex of the platform subdomain — landing page for operators.
    # Authenticated via oauth2-proxy + GitHub (see Caddyfile).
    apex       = var.subdomain_label
    registry   = "registry.${var.subdomain_label}"
    logs       = "logs.${var.subdomain_label}"
    alerts     = "alerts.${var.subdomain_label}"
    dashboards = "dashboards.${var.subdomain_label}"
    # Dex OIDC issuer — public discovery endpoint plus the GitHub OAuth
    # callback URI. Must be HTTPS (Let's Encrypt via Caddy) because Zot
    # refuses to talk to a non-TLS OIDC issuer.
    dex = "dex.${var.subdomain_label}"
  }
}

resource "digitalocean_record" "platform" {
  for_each = local.dns_records

  domain = var.domain
  type   = "A"
  name   = each.value
  value  = digitalocean_reserved_ip.platform.ip_address
  ttl    = 300
}
