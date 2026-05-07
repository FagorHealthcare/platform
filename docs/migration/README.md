# Infrastructure Migration Plan

A pragmatic, multi-pillar plan to reduce the platform's monthly run-rate
while improving the security posture (vulnerability scanning at the
registry, fewer hardcoded credentials, off-cloud log archive) and the
reliability posture (no more silent log-ingest drops, controlled
retention).

Status: **proposed**. Nothing in here has been executed. Each pillar is
a self-contained file that can be picked up and worked on independently,
but some unblock others — see "Sequencing" below.

## Current monthly cost

Verified via `doctl` against the live DigitalOcean account; AWS figure
from the most recent invoice.

| Item | Detail | Approx. cost |
|---|---|---|
| `md-dev-cluster` nodes | 4× `s-1vcpu-2gb` (~81% memory utilisation) | $48 |
| `md-pre-cluster` nodes | 3× `c-2` CPU-optimised (~3% CPU, 64% memory) | $126 |
| Load balancers | 4× `lb-small` (HTTPS + MQTT, both clusters) | $48 |
| `md-dev-postgresql` | `db-s-1vcpu-1gb` managed Postgres | $15 |
| `md-pre-postgresql` | `db-s-2vcpu-4gb` managed Postgres | $60 |
| PVCs | 3× 5 GiB block storage (NodeRed/n8n state) | $1.5 |
| AWS Elasticsearch | log sink for both clusters (218 MiB used / 49 GiB allocated) | ~$77 / €70 |
| DockerHub | `gailen/*` images (build + pulls) | $5–10 |
| **Total** | | **~$390 / €355** |

DOKS standard control planes are free. HA control plane (not used)
would add $40/mo per cluster.

## The six pillars

In recommended priority order:

| # | Pillar | Summary | Net delta |
|---|---|---|---|
| [01](01-rightsizing.md) | **Rightsizing** | Drop dev replicas to 1; replace `c-2` in pre with `s-2vcpu-4gb`; optionally consolidate dev nodes. Reversible in minutes. | **−$54/mo** |
| [06](06-platform-tier.md) | **Platform tier (droplet)** | Dedicated `s-2vcpu-4gb` Debian droplet running `docker compose` (Caddy + Zot + Loki) on `*.platform.fmd.fagorhealthcare.com`. Backed by Spaces + AWS S3 DR. Terraform-provisioned. | **+$33/mo** (hosting cost; net negative when paired with 03) |
| [02](02-registry.md) | **Self-hosted registry** | Zot service in the platform droplet's compose stack, Trivy CVE scanning, Spaces backend, AWS S3 mirror. Replaces DockerHub. | **~$0** (gains scanning + ends hardcoded creds) |
| [03](03-logging.md) | **Vector → Loki** | Same Vector pipeline, swap the sink. Loki service in the platform droplet, Spaces backend, 365-day retention. | **−$70/mo** |
| [04](04-cluster-topology.md) | **Cluster topology** | Decision: keep app clusters separate; do **not** host platform services in either app cluster — they live on the dedicated droplet (pillar 06). | **−$0/mo direct** |
| [05](05-not-doing.md) | **Things explicitly rejected** | DOKS → k3s, DO Container Registry, Loki-per-cluster, single unified cluster, platform-services-in-dev-cluster. | n/a |

Cumulative final state: **~$278/mo** vs **~$381/mo** today (DOKS +
AWS ES) — **net −$103/mo (~−27%)** while gaining vulnerability
scanning at the registry, decommissioning the hardcoded DockerHub
credential in `add_tag.sh`, gaining 365-day controlled log retention,
and putting platform services on a dedicated host with terraformed IaC
and dual-cloud DR.

### Final-state cost breakdown

| Item | Monthly |
|---|---|
| `md-dev-cluster` rightsized | $48 |
| `md-pre-cluster` rightsized | $72 |
| Load balancers (4×) | $48 |
| Postgres (dev + pre) | $75 |
| PVCs | $1.50 |
| Platform droplet | $24 |
| Droplet weekly snapshot | $3 |
| Spaces (registry + logs) | $5 |
| AWS S3 IA backup | ~$1 |
| DockerHub (canceled) | $0 |
| AWS ES (canceled) | $0 |
| **Total** | **~$278/mo** |

## What we are NOT doing and why

See [05-not-doing.md](05-not-doing.md). The short version: collapsing
onto self-managed k3s droplets, switching to DO's Container Registry
product, running a per-cluster Loki, unifying the two app clusters,
and **hosting platform services inside the dev cluster** were each
considered and rejected for documented reasons. Capture them there
before revisiting.

## Sequencing

```
01-rightsizing  (independent — $54/mo, reversible)
   (1 hour)

06-platform-tier  ──┬──►  02-registry
   (~3 days)        │       (~1 day)
                    │
                    └──►  03-logging
                            (~1 day + 30d parallel)
04-topology decision: locked (Scenario C — droplet)
```

01 has no arrow pointing into it because nothing depends on it; it
runs in parallel with everything else whenever convenient.

Recommended sequence:

1. **Pillar 01 first.** Standalone cost saving (~$54/mo from the pre
   node-pool resize alone), reversible in minutes, and unrelated to
   the rest of the plan. Earlier drafts treated 01 as a prerequisite
   for hosting platform services in the dev cluster; that design was
   rejected (see pillar 04). 01 is now first only because it pays
   back immediately.
2. **Pillar 06 second.** Provisions the platform droplet, Spaces
   buckets, DNS zone, and Caddy. Nothing else can land until this
   exists.
3. **Pillars 02 and 03 in either order, after 06.** Both are
   single-day adds to the platform droplet's compose stack. They are
   independent of each other; pick whichever is more pressing.
4. **Pillar 04 is documentation only** — no work product, just records
   the architectural decision (Scenario C — dedicated droplet)
   superseding the earlier "platform in dev cluster" recommendation.

Each pillar's file lists its concrete `Depends on:` line at the top.

### Cross-cutting principle: dev-first, validated, then pre

Every change with cluster-side impact lands on `md-dev-cluster` first,
**stays there long enough to expose the failure modes**, and only then
moves to `md-pre-cluster`. Pre serves real production traffic
(`app.fagorhealthcare.com`, `medicaldispenser-sw.cinfa.com`) — its
risk budget is much smaller than dev's.

How this applies per pillar:

| Pillar | Dev-first action | Bake time before touching pre |
|---|---|---|
| **01 rightsizing** | Drop dev replicas to 1 and resize node pool. Watch for OOM, eviction, slow rollouts. | ~3 days of normal traffic. |
| **06 platform tier** | The droplet is *its own* "dev" — provision it, bring up Caddy + dummies, smoke-test TLS. Nothing in pre is touched. | n/a (host is shared from day 1, but cluster impact is zero until 02/03 land). |
| **02 registry** | Migrate ONE dev service's `cd.yaml` to push to Zot, validate cluster pulls. Then migrate the rest of dev. | At least 1 successful dev deploy through Zot before changing any `release.yml` for pre. |
| **03 logging** | Add the Loki sink to **dev's** `vector.yaml` only. Run the validation protocol against dev's traffic for ≥1 week. | Only after dev's parallel-run validation passes do we add the Loki sink to pre's `vector.yaml`. The 30-day cutover clock then runs on pre's data. |

If any pillar's dev-first stage reveals a regression, the rollback is
local to dev — no impact on pre, no production minutes lost. This is
the same discipline `release.yml` already encodes for application
deploys (dev auto-deploys on merge, pre needs an explicit dispatch);
applying it to platform changes keeps the same risk posture.

## Cross-cutting concerns

- The **`cinfa-adhoc-cert` DigiCert wildcard** (manual, not cert-manager-
  managed — see [`../OPERATIONS.md`](../OPERATIONS.md) and
  [`../../k8s/CLAUDE.md`](../../k8s/CLAUDE.md)) must survive every
  pillar unchanged. No pillar's ingress changes may add
  `cert-manager.io/issuer` to its entry. The platform droplet's Caddy
  is on a different DNS zone (`*.platform.fmd.fagorhealthcare.com`) so
  this concern only applies to the app clusters' NGINX ingress.
- All migration work must preserve the `<branch>.<run_number>` immutable
  tag contract documented in [`../DEPLOYMENT.md`](../DEPLOYMENT.md).
  Floating tags `dev`/`prod`/`latest` keep their current meaning.
- `fhctl` integration points (registry, logs) are noted per pillar;
  they are follow-on work, not blockers.
- The new DNS zone `platform.fmd.fagorhealthcare.com` requires a one-time
  delegation from the parent `fagorhealthcare.com` zone — see pillar
  06.
