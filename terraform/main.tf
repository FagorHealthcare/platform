# =====================================================================
# Platform droplet, reserved IP, firewall, and SSH key registration.
#
# Provisions the substrate that pillars 02 (registry / Zot) and 03
# (logging / Loki) land on. The droplet is intentionally stateless —
# durable state lives in Spaces (see spaces.tf).
# =====================================================================

provider "digitalocean" {
  token             = var.do_token
  spaces_access_id  = var.do_spaces_access_id
  spaces_secret_key = var.do_spaces_secret_key
}

# ---------------------------------------------------------------------
# SSH key registered with DO. Used to seed `~root/.ssh/authorized_keys`
# on the droplet at first boot.
# ---------------------------------------------------------------------
resource "digitalocean_ssh_key" "operator" {
  name       = "${var.droplet_name}-operator"
  public_key = var.ssh_public_key
}

# ---------------------------------------------------------------------
# The droplet itself. cloud-init installs Docker + base packages, but
# does NOT yet pull the docker-compose stack (Caddy/Zot/Loki) — that's
# a follow-on PR per pillar 06's effort breakdown.
# ---------------------------------------------------------------------
resource "digitalocean_droplet" "platform" {
  image      = "debian-12-x64"
  name       = var.droplet_name
  region     = var.region
  size       = var.droplet_size
  ssh_keys   = [digitalocean_ssh_key.operator.fingerprint]
  monitoring = var.enable_droplet_monitoring
  backups    = var.enable_droplet_backups
  ipv6       = true

  tags = ["platform", "managed-by-terraform"]

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    letsencrypt_email      = var.letsencrypt_email
    region                 = var.region
    do_spaces_access_id    = var.do_spaces_access_id
    do_spaces_secret_key   = var.do_spaces_secret_key
    spaces_bucket_registry = var.spaces_bucket_registry
    spaces_bucket_logs     = var.spaces_bucket_logs
  })

  # cloud-init's user_data is "forces replacement" by provider design.
  # Once the droplet is provisioned and bootstrapped, we never want a
  # stray cloud-init template edit to nuke /var/lib/registry, /loki,
  # or the Caddy ACME state. To re-bootstrap intentionally:
  #   terraform apply -replace=digitalocean_droplet.platform
  lifecycle {
    ignore_changes = [user_data]
  }
}

# ---------------------------------------------------------------------
# Reserved IP — anchors a stable public IP across droplet rebuilds.
# DNS records (dns.tf) point at this, NOT at droplet.ipv4_address, so
# `terraform destroy && terraform apply` does not require DNS edits.
# ---------------------------------------------------------------------
resource "digitalocean_reserved_ip" "platform" {
  region = var.region
}

resource "digitalocean_reserved_ip_assignment" "platform" {
  ip_address = digitalocean_reserved_ip.platform.ip_address
  droplet_id = digitalocean_droplet.platform.id
}

# ---------------------------------------------------------------------
# Cloud firewall.
#
# Inbound:
#   - 22/tcp  from operator IPs only        (operator SSH)
#   - 80/tcp  from anywhere (v4 + v6)       (Caddy HTTP→HTTPS redirect, ACME http-01)
#   - 443/tcp from anywhere (v4 + v6)       (Caddy HTTPS for registry+logs subdomains)
#   - ICMP    from anywhere                 (basic reachability checks)
#
# Outbound: all (Caddy needs ACME, Docker needs registries, Zot/Loki
# need Spaces, Vector pushes from clusters elsewhere — not blocked here
# because clusters are inbound; this is droplet egress only).
# ---------------------------------------------------------------------
resource "digitalocean_firewall" "platform" {
  name        = "${var.droplet_name}-fw"
  droplet_ids = [digitalocean_droplet.platform.id]

  # ---- Inbound ----
  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = var.operator_ssh_source_ips
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "icmp"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # ---- Outbound (allow all) ----
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
