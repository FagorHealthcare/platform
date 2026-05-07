# =====================================================================
# DO Spaces buckets.
#
#   platform-registry   — Zot's S3 storage backend (image blobs)
#   platform-logs       — Loki's S3 storage backend (chunks + indices)
#
# Both are private, versioned, and `prevent_destroy`-protected. To
# intentionally tear them down, edit the lifecycle block below to
# `prevent_destroy = false`, run `terraform apply`, then `terraform
# destroy`. Do not delete them on a whim — image pulls and log queries
# both depend on the data they hold.
# =====================================================================

# ---------------------------------------------------------------------
# Registry bucket (consumed by Zot's S3 driver).
# Multipart uploads come from layer pushes; abandoned ones (broken
# CI runs, network blips) get garbage-collected after 7 days.
# ---------------------------------------------------------------------
resource "digitalocean_spaces_bucket" "registry" {
  name   = var.spaces_bucket_registry
  region = var.region
  acl    = "private"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    id      = "abort-incomplete-multipart"
    enabled = true

    abort_incomplete_multipart_upload_days = 7
  }

  lifecycle {
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------
# Logs bucket (consumed by Loki's S3 backend).
# Same incomplete-multipart cleanup. NO delete-after lifecycle — Loki
# manages its own retention via `limits_config.retention_period`
# (see pillar 03 / loki-config.yaml).
# ---------------------------------------------------------------------
resource "digitalocean_spaces_bucket" "logs" {
  name   = var.spaces_bucket_logs
  region = var.region
  acl    = "private"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    id      = "abort-incomplete-multipart"
    enabled = true

    abort_incomplete_multipart_upload_days = 7
  }

  lifecycle {
    prevent_destroy = true
  }
}
