# =====================================================================
# Provider and Terraform version constraints.
#
# The state backend is intentionally LEFT AS LOCAL for the v1 bootstrap.
# The operator's `terraform.tfstate` lives on their laptop only. Before
# this module is ever shared with the team, promote to a Spaces-backed
# S3 backend by uncommenting the block below and running
#   `terraform init -migrate-state`
# from a workstation that has the Spaces access keys exported as
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY.
# =====================================================================

terraform {
  required_version = ">= 1.6"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.40"
    }
  }

  # ---------------------------------------------------------------------
  # FUTURE: Spaces-backed remote state. Uncomment + create the
  # `platform-tfstate` Spaces bucket BEFORE first use, then run
  # `terraform init -migrate-state`.
  #
  # backend "s3" {
  #   endpoints = {
  #     s3 = "https://fra1.digitaloceanspaces.com"
  #   }
  #   bucket                      = "platform-tfstate"
  #   key                         = "platform/terraform.tfstate"
  #   region                      = "us-east-1" # ignored by Spaces but required by the s3 backend
  #   skip_credentials_validation = true
  #   skip_metadata_api_check     = true
  #   skip_region_validation      = true
  #   skip_requesting_account_id  = true
  #   skip_s3_checksum            = true
  #   use_path_style              = false
  #   # Credentials come from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
  #   # (set them to your DO Spaces access id / secret key).
  # }
  # ---------------------------------------------------------------------
}
