# INFRASTRUCTURE — Clusters, Cloud, Registry, Observability

## Compute: DigitalOcean Managed Kubernetes (DOKS)

Two clusters, both region `fra1` (Frankfurt):

| Cluster | Context name | Serves env | Notes |
|---|---|---|---|
| **md-dev-cluster** | `do-fra1-md-dev-cluster` | `dev-0` | Internal dev/staging. Access: `kubectl` with token from `md-dev-cluster-kubeconfig.yaml` (in `k8s/` repo) or DigitalOcean PAT. |
| **md-pre-cluster** | `do-fra1-md-pre-cluster` | `pre` (= production) | Live customer traffic. Same access model. |

### Node pools

Each cluster runs a basic node pool of 4 nodes (typical sizing observed in the 2026-03-23 incident report: `md-dev-basic-5w3n4`, `5w3nh`, `5w3nk`, `5w3ni`). Storage class is `do-block-storage`.

### AWS EKS (legacy)

The `md-core/Jenkinsfile` references an AWS EKS cluster in `eu-west-1`. This path is **no longer the active deploy target** — GitHub Actions to DOKS supersedes it. Treat AWS as cold storage; do not assume it is current.

## Database: DigitalOcean Managed Postgres

Single managed cluster account, two logical pools:

| Env | Connection | DB | Pool size |
|---|---|---|---|
| dev | `md-dev-postgresql-do-user-2821405-0.b.db.ondigitalocean.com:25061` | `dev-pool` | 18–25 |
| pre | `md-pre-postgresql-do-user-2821405-0.b.db.ondigitalocean.com:25061` | `pre-pool` | 10 |

- TLS required (port 25061 is the SSL endpoint)
- Connection pooling via Agroal (Quarkus default), 30s acquisition timeout
- All three Quarkus services (md-core, md-auth, md-resi-back) share the same physical DB but maintain **independent Flyway history tables** (`flyway_schema_history`, `flyway_resi_schema_history`, etc.) — migrations never collide
- Quartz tables also live here (clustered scheduler)
- Backups: DO managed snapshots **plus** the `md-backup` CronJob that uploads `pg_dump` to S3

## Object storage: AWS S3

Bucket per environment (configured in `k8s/environments/<env>/kustomization.yaml` ConfigMap):

- `medicaldispenser-dev-backup`
- `medicaldispenser-backup` (used by pre/prod)

S3 credentials live in the `s3-backup-key` Secret. Mounted via `s3fs` (FUSE) inside the `md-backup` CronJob.

## DNS & Hostnames

| Hostname | Env | Purpose |
|---|---|---|
| `md.k8s.gailen.net` | dev | md-core (paths under it) + md-pwa root |
| `app.k8s.gailen.net` | dev | md-pwa standalone |
| `resi.k8s.gailen.net` | dev | md-resi-back/front |
| `fmd.k8s.gailen.net` | dev | Combined ingress for md-resi-* + md-core/auth |
| `n8n.fmd.k8s.gailen.net` | dev | n8n editor |
| `app.fagorhealthcare.com` | pre | Production md-pwa + md-core |
| `fmd.fagorhealthcare.com` | pre | Production combined md-resi + md-core |
| `medicaldispenser-sw.cinfa.com` | pre | Production Cinfa-branded entrypoint (md-resi front+back) |
| `nodered.fmd.fagorhealthcare.com` | pre | Production NodeRed |

DNS records are managed externally to this repo (registrar TBD; Gailen owns `gailen.net`, customer Cinfa owns `cinfa.com`). The DigitalOcean Load Balancer IP that NGINX Ingress provisions is the A-record target.

## Ingress topology

NGINX Ingress Controller (installed from the official ingress-nginx DO manifest, v1.0.4 in current deployment) creates a DigitalOcean Load Balancer automatically and terminates TLS.

Per-environment ingress files:

- `k8s/environments/dev-0/ingress.yaml`
- `k8s/environments/pre/ingress.yaml`

Each defines multiple `Ingress` resources (one per hostname), each with path-based routing to backend services. Path examples for `app.fagorhealthcare.com`:

- `/seguimiento`, `/wu/`, `/auth/`, `/user/`, `/shc/`, `/log/`, `/test/`, `/q/` → `md-core:8080`
- `/health/md-core`, `/health/md-auth`, `/health/md-resi-back`, `/health/md-resi-front` → respective service `:8080`
- `/` → `md-pwa:8080`

Ingress annotations: `nginx.ingress.kubernetes.io/proxy-read-timeout: 300`, `proxy-body-size: 50m`.

## TLS / Certificates

Two certificate systems run in parallel:

### Let's Encrypt (cert-manager, automated)

- `cert-manager` v1.6.0 installed cluster-wide
- `ClusterIssuer letsencrypt-prod` uses HTTP-01 challenge
- Manages secrets `fagor-do-tls` (main domains) and `fagor-nodered-tls`
- Auto-renews before expiry
- Pre-prod also has a `digitalocean-dns` secret enabling DNS-01 challenge as fallback

### DigiCert wildcard (manual)

- `cinfa-adhoc-cert` Secret holds a DigiCert wildcard cert for `*.cinfa.com`
- Renewed manually once per year by replacing the secret
- Historical certs archived under `k8s/cinfassl/<year>/`
- **Do not annotate the corresponding Ingress entry with `cert-manager.io/issuer`** — that would silently overwrite this with a Let's Encrypt cert and break Cinfa endpoints
- After rotating: `kubectl rollout restart deployment -n ingress-nginx ingress-nginx-controller`

Full renewal runbook: see `k8s/CLAUDE.md`.

## Image registry: DockerHub

All container images live under the `gailen/` namespace on DockerHub:

- `gailen/md-core`
- `gailen/md-pwa`
- `gailen/md-auth`
- `gailen/md-resi-back`
- `gailen/md-resi-front`
- `gailen/md-backup`
- `gailen/mkdocs-fmd` (manual preview)

Image-pull credentials are stored in the `md-dockerhub-regcred` Secret and referenced from each Deployment's `imagePullSecrets`.

### Tag conventions

Two kinds of tags coexist:

1. **Build tags** — `<branch>.<run_number>` (e.g. `main.247`, `develop.13`). These are immutable, append-only, and are what CI pushes. Use these for precise rollbacks.
2. **Floating tags** — `dev`, `prod`, `latest`, `<branch>.latest`. These are **manifest aliases** re-pointed by `add_tag.sh` after each successful deploy. Convenient but ambiguous; **never deploy from a floating tag in CI** — always pin to a build tag.

`add_tag.sh` re-tags by hitting the DockerHub registry HTTP API directly (no `docker pull` / `docker push` round trip) — it fetches the manifest under the old tag and PUTs it under the new tag.

## Logging: Vector → Logtail

`vector` runs as a DaemonSet (manifest in `k8s/vector-dev0/`):

- Image: `timberio/vector:0.19.0-debian`
- Source: `kubernetes_logs` (reads container stdout from kubelet)
- Transforms: timestamp normalization, field extraction, platform detection (Apache, Nginx, Postgres, Kubernetes events)
- Sink: Logtail.com (token in cluster Secret)

All Quarkus services are configured to emit JSON logs (`quarkus.log.console.json=true`) so Vector can parse them into structured fields.

## Error tracking: Sentry

Currently only `md-resi-front` integrates Sentry directly (`@sentry/angular-ivy`). DSN is in env config. Backend services do not currently report to Sentry.

## Analytics

Google Analytics ID `G-72YXJ1RJD` is shared across both PWAs (set via `config.js`).

## Observability gaps

- No Prometheus/Grafana scraping the cluster
- No tracing in production (Jaeger configured in `md-core/docker-compose.yml` for local dev only)
- No alert rules / SLOs defined
- Logtail is the only centralized log destination; no LTS archival

## Inbound integration endpoints

| Endpoint | Owner | Used by |
|---|---|---|
| `https://nrapi.fmd.fagorhealthcare.com/v0/versionOnline` | external/internal — version-tracking API | All CI workflows POST here after each successful deploy |
| `https://cima.aemps.es/cima/rest` | Spanish gov. (AEMPS) | md-resi-back drug lookups |
| `https://cinfa.lightning.force.com/services` | Salesforce | md-auth OAuth |
| `https://cinfa--dev.sandbox.my.salesforce.com/services` | Salesforce sandbox | md-auth dev |
| `mqtt://67.207.73.146:1883` | self-hosted Mosquitto | md-core SHC device traffic |

## Outbound calls

- **Twilio** — WhatsApp Business API (account SID + auth token in app config)
- **Sentry** — `*.sentry.io`
- **DockerHub** — image pulls
- **Logtail** — `in.logs.betterstack.com`
- **GitHub** — git submodule fetches at build time
