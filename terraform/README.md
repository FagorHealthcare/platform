# Platform-tier Terraform module

Provisions the **substrate** that pillars 02 (registry / Zot) and 03
(logging / Loki) land on:

- 1× DigitalOcean Debian 12 droplet (`s-2vcpu-4gb`, fra1, monitoring + weekly snapshots)
- 1× reserved IPv4 attached to it (anchors DNS across rebuilds)
- 1× cloud firewall (SSH locked to operator CIDRs, 80/443 open to the world)
- 2× DO Spaces buckets — `platform-registry` and `platform-logs`, both
  versioned, both `prevent_destroy`-protected
- DNS A records under `fmd.fagorhealthcare.com`:
  - `registry.platform.fmd.fagorhealthcare.com`
  - `logs.platform.fmd.fagorhealthcare.com`
- cloud-init that installs Docker + base packages — the docker-compose
  stack itself (Caddy + Zot + Loki) is **not** yet provisioned here

Cross-reference the migration plan: [`../docs/migration/06-platform-tier.md`](../docs/migration/06-platform-tier.md).

## Prerequisites

- Terraform `>= 1.6` installed locally
- A DigitalOcean account with:
  - An API token with full read+write on Droplet, Reserved IP, Firewall, Domain, SSH key, **and** Spaces scopes
  - A Spaces access key pair (generated separately under **API → Spaces Keys**)
- The DNS zone `fmd.fagorhealthcare.com` already managed by this DO
  account. Verify:
  ```sh
  doctl compute domain list | grep fmd.fagorhealthcare.com
  ```
  If it's not there, create / delegate the zone before applying.
- An SSH keypair on the operator's laptop. Public key will be uploaded
  to DO and seeded into `~root/.ssh/authorized_keys` via cloud-init.

## State backend

**v1 uses LOCAL state.** `terraform.tfstate` lives on the operator's
laptop and nowhere else. This is fine for the initial bootstrap (single
operator, single machine) but **must be promoted to a Spaces-backed
remote backend before the team starts using this module**. The
commented-out `backend "s3"` block in [`versions.tf`](versions.tf)
shows exactly how — uncomment, create a `platform-tfstate` Spaces
bucket out-of-band, then run `terraform init -migrate-state`.

## Bootstrap flow

1. Copy and fill in your tfvars:
   ```sh
   cp terraform.tfvars.example terraform.tfvars
   $EDITOR terraform.tfvars
   ```
2. `terraform init` — downloads the DO provider into `.terraform/`.
3. `terraform plan -out plan.tfplan` — **review carefully.** Confirm:
   - Droplet region/size match what you expect.
   - DNS records target the reserved IP (not `0.0.0.0`).
   - Spaces buckets do NOT already exist with content you care about
     (the names are global within DO — collisions fail loudly).
4. `terraform apply plan.tfplan`.
5. Wait ~2 minutes for cloud-init to finish (Docker install + apt upgrades).
   Then SSH in and verify:
   ```sh
   ssh root@$(terraform output -raw droplet_ipv4)
   docker --version
   systemctl is-active docker
   ```
6. The droplet now runs an empty Docker daemon. The follow-on commit
   lands the docker-compose stack (Caddyfile, zot-config.json,
   loki-config.yaml, etc.) under `/opt/platform/`.

## Outputs you'll need next

After apply, the docker-compose stack consumes these values:

| Output | Used in |
|---|---|
| `droplet_ipv4` | Operator monitoring, SSH, manual smoke tests |
| `spaces_registry_endpoint` + `spaces_registry_bucket` | `zot-config.json` storageDriver |
| `spaces_logs_endpoint` + `spaces_logs_bucket` | `loki-config.yaml` common.storage.s3 |
| `dns_records` | Caddyfile site blocks |
| `ssh_command` | First-login convenience |

## Destroy / recovery

`terraform destroy` rebuilds-from-scratch in ~3 minutes — the droplet
is intentionally stateless (Caddy ACME state regenerates, Zot blobs are
in Spaces, Loki chunks are in Spaces, the compose file is in git).

The two Spaces buckets carry `prevent_destroy = true` to protect their
contents. To intentionally delete them:

1. Edit [`spaces.tf`](spaces.tf), set `prevent_destroy = false` on the
   bucket(s) you intend to delete.
2. `terraform apply` (no resources change yet — only the lifecycle metadata).
3. `terraform destroy -target=digitalocean_spaces_bucket.registry`
   (or `.logs`).

You almost certainly do NOT want to do this; bucket deletion takes log
chunks and image blobs with it.

## Cost estimate

See the cost table in [`../docs/migration/06-platform-tier.md`](../docs/migration/06-platform-tier.md#cost-detail)
— ~€30/mo all-in for droplet + snapshot + Spaces.

## Files in this module

| File | Purpose |
|---|---|
| `versions.tf` | Terraform + provider version constraints; commented Spaces backend block |
| `variables.tf` | All inputs (required vs defaulted) |
| `main.tf` | Droplet, reserved IP, firewall, SSH key |
| `dns.tf` | A records under the existing `fmd.fagorhealthcare.com` zone |
| `spaces.tf` | `platform-registry` and `platform-logs` buckets |
| `outputs.tf` | Connection details for the follow-on compose stack |
| `cloud-init.yaml.tftpl` | First-boot bootstrap (Docker, base packages, stub `.env`) |
| `terraform.tfvars.example` | Copy → `terraform.tfvars`, then fill in |

## Conventions

- `.terraform.lock.hcl` IS committed to the repo (provider version
  pinning for reproducibility — the Terraform docs recommend this).
- `.terraform/`, `terraform.tfstate*`, `terraform.tfvars`, and `*.tfplan`
  are gitignored.
- All resources tagged `platform` + `managed-by-terraform` so they show
  up filterably in the DO console and in `doctl compute droplet list --tag-name platform`.

## What this module does NOT yet do

- Pull or start the docker-compose stack (Caddy, Zot, Loki) — that's
  the next commit.
- Configure DNS for `fhctl` integration endpoints — see
  [`../docs/fhctl-DESIGN.md`](../docs/fhctl-DESIGN.md).
- Provision the AWS S3 mirror bucket / lifecycle rules — those live in
  the `md-backup` repo (cluster-side CronJob).
- Set up monitoring beyond DO's native agent. UptimeRobot / external
  liveness checks are operator-managed for now.
