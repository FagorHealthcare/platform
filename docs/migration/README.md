# Infrastructure Migration Plan

A pragmatic, multi-pillar plan to reduce the platform's monthly run-rate from
**~€355** to **~€220–250** while improving the security posture (vulnerability
scanning at the registry, fewer hardcoded credentials, off-cloud log archive).

Status: **proposed**. Nothing in here has been executed. Each pillar is a
self-contained file that can be picked up and worked on independently, but
some unblock others — see "Sequencing" below.

## Current monthly cost

Verified via `doctl` against the live DigitalOcean account; AWS figure from
the most recent invoice.

| Item | Detail | Approx. cost |
|---|---|---|
| `md-dev-cluster` nodes | 4× `s-1vcpu-2gb` (~81% memory utilisation) | $48 |
| `md-pre-cluster` nodes | 3× `c-2` CPU-optimised (~3% CPU, 64% memory) | $126 |
| Load balancers | 4× `lb-small` (HTTPS + MQTT, both clusters) | $48 |
| `md-dev-postgresql` | `db-s-1vcpu-1gb` managed Postgres | $15 |
| `md-pre-postgresql` | `db-s-2vcpu-4gb` managed Postgres | $60 |
| PVCs | 3× 5 GiB block storage (NodeRed/n8n state) | $1.5 |
| AWS Elasticsearch | log sink for both clusters | €70 |
| DockerHub | `gailen/*` images (build + pulls) | $5–10 |
| **Total** | | **~$390 / €355** |

DOKS standard control planes are free. HA control plane (not used) would add
$40/mo per cluster.

## The five pillars

In recommended priority order (cheapest-first / lowest-risk-first, then by
size of saving):

| # | Pillar | Summary | Net delta |
|---|---|---|---|
| [01](01-rightsizing.md) | **Rightsizing** | Drop dev replicas to 1; replace `c-2` in pre with `s-2vcpu-4gb`; optionally consolidate dev nodes. Reversible in minutes. | **−$54/mo** |
| [02](02-registry.md) | **Self-hosted registry** | Zot + DO Spaces backend, Trivy CVE scanning, S3 IA mirror via `md-backup`. Replaces DockerHub. | **~$0** (gains scanning + ends hardcoded creds) |
| [03](03-logging.md) | **Vector → Loki** | Same Vector pipeline, swap the sink. Loki monolithic on Spaces. | **−$70/mo** |
| [04](04-cluster-topology.md) | **Cluster topology** | Keep app clusters separate; consolidate **platform** services (registry, logs, cert-manager) into one. | **−$0 to −$24/mo** |
| [05](05-not-doing.md) | **Things explicitly rejected** | DOKS → k3s, DO Container Registry, Loki-per-cluster, single unified cluster. | n/a |

Cumulative target: **−~€105/mo** (~30%) without losing capability, with two
non-monetary wins (vulnerability scanning at the registry, decommissioning the
hardcoded DockerHub credential in `add_tag.sh`).

## What we are NOT doing and why

See [05-not-doing.md](05-not-doing.md). The short version: collapsing onto
self-managed k3s droplets, switching to DO's Container Registry product,
running a per-cluster Loki, and unifying the two app clusters were each
considered and rejected for documented reasons. Capture them there before
revisiting.

## Sequencing

```
01-rightsizing  ──────►  02-registry  ──────►  03-logging
   (1 hour)                (~3.5 days)            (~1 day + 30d parallel)
       │                        │                       │
       │                        │                       │
       └────────────────────────┴────────► 04-topology decision
                                              (informs WHERE 02/03 land)
```

Recommended sequence:

1. **Pillar 01 first.** Free, reversible, and creates ~512 MiB of memory
   headroom in dev that pillars 02 and 03 will consume.
2. **Pillar 04 decision second.** It does not require code changes, but it
   determines *where* the new platform components from pillars 02 and 03 are
   deployed. Decide before building anything.
3. **Pillar 02 (registry) third.** Live in parallel with DockerHub for at
   least one full release cycle on every service before flipping any
   `imagePullSecrets`.
4. **Pillar 03 (logging) last.** Run Loki + AWS ES side-by-side for ~30 days
   so we have apples-to-apples evidence Loki captured everything before we
   cancel the AWS bill.

Each pillar's file lists its concrete `Depends on:` line at the top.

## Cross-cutting concerns

- The **`cinfa-adhoc-cert` DigiCert wildcard** (manual, not cert-manager-
  managed — see [`../OPERATIONS.md`](../OPERATIONS.md) and
  [`../../k8s/CLAUDE.md`](../../k8s/CLAUDE.md)) must survive every pillar
  unchanged. No pillar's ingress changes may add `cert-manager.io/issuer`
  to its entry.
- All migration work must preserve the `<branch>.<run_number>` immutable tag
  contract documented in [`../DEPLOYMENT.md`](../DEPLOYMENT.md). Floating
  tags `dev`/`prod`/`latest` keep their current meaning.
- `fhctl` integration points (registry, logs) are noted per pillar; they are
  follow-on work, not blockers.
