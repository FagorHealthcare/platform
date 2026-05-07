# Pillar 04 — Cluster Topology

Status: **decided** — keep app clusters separate, host platform services on a dedicated droplet (see [06-platform-tier.md](06-platform-tier.md)) | Estimated savings: **−$0/mo direct** (platform-tier savings counted in pillars 03/06) | Effort: **architectural decision; no direct work** | Risk: **low** | Depends on: **none** (but informs 02, 03, and 06)

Should we collapse `md-dev-cluster` and `md-pre-cluster` into a single
DOKS cluster? And: where do shared platform services (registry, logs)
live? This pillar exists to record the trade-offs explicitly.

**Decided outcome (TL;DR):**

1. **Keep `md-dev-cluster` and `md-pre-cluster` as separate DOKS clusters.**
   No consolidation.
2. **Do not host platform services in either app cluster.** Pillars 02
   (Zot registry) and 03 (Loki) land on a **dedicated single droplet**
   running `docker compose`, on its own subdomain
   `*.platform.fagorhealthcare.com`. See [06-platform-tier.md](06-platform-tier.md)
   for the full design.

This decision supersedes the earlier "Scenario B" (platform-services-
in-dev-cluster) recommendation. Scenario B is now logged as a rejected
alternative — see [05-not-doing.md](05-not-doing.md).

## The questions

Three scenarios were considered:

### Scenario A — Fully unified single cluster

- One DOKS cluster, two namespaces (`dev-0`, `pre`).
- Single NGINX ingress controller, single load balancer.
- Apps share node pool(s).

### Scenario B — Split apps, platform-in-dev-cluster (originally recommended, now superseded)

- App clusters stay split: `md-dev-cluster` for dev, `md-pre-cluster`
  for prod.
- Platform components (registry, Loki, Grafana) live in the dev cluster
  and are consumed cross-cluster by prod.

### Scenario C — Split apps, platform on a dedicated droplet (selected)

- App clusters stay split as in Scenario B.
- Platform components live on a single fra1 droplet running
  `docker compose`, on its own DNS zone, with its own backups and IaC.
- See [06-platform-tier.md](06-platform-tier.md).

## Honest cost analysis

### Final-state costs (with rightsizing + droplet platform tier)

| Item | Monthly |
|---|---|
| `md-dev-cluster` rightsized (4× `s-1vcpu-2gb`) | $48 |
| `md-pre-cluster` rightsized (3× `s-2vcpu-4gb`) | $72 |
| Load balancers (4× `lb-small`) | $48 |
| `md-dev-postgresql` | $15 |
| `md-pre-postgresql` | $60 |
| PVCs (3× 5 GiB) | $1.50 |
| **Apps subtotal** | **~$245** |
| Platform droplet `s-2vcpu-4gb` | $24 |
| Droplet weekly snapshot | $3 |
| Spaces (`platform-registry` + `platform-logs`) | $5 |
| AWS S3 IA backup (~5 GiB) | ~$1 |
| **Platform subtotal** | **~$33** |
| **Total final state** | **~$278** |
| (vs current ~$304 + AWS ES ~$77 = ~$381) | **−$103/mo** |

### If pools were fully shared (Scenario A — rejected)

| Saving source | Best case |
|---|---|
| Drop one set of node pools | up to $48/mo if dev's nodes vanish into spare capacity on pre's pool |
| Drop one HTTPS load balancer | $12/mo |
| Drop one MQTT load balancer | $12/mo (only if MQTT can share with HTTPS LB — currently not configured to) |
| Drop one managed Postgres? | unlikely — see below |
| **Theoretical max** | **~$72/mo** |

But: production should not co-tenant with dev on the same node pool.
The production node pool is sized for prod traffic with a margin;
adding dev's load means either a bigger pool (negating savings) or
accepting that a runaway dev pod starves prod. In practice we'd run
**separate node pools per env** even in Scenario A, so:

### If we keep separate node pools (realistic Scenario A)

| Saving source | Realistic |
|---|---|
| Single control plane | **$0** (DOKS standard CP is free anyway) |
| One HTTPS LB consolidated | **$12/mo** |
| One MQTT LB consolidated | **$12/mo** (if reachable) |
| Postgres consolidation | **$0** — already one DO Postgres account; both pools live there |
| **Realistic max** | **~$24/mo** |

So: **the topology change buys at most $24/mo on top of the other
pillars**, and only if we accept real risks documented below.

## Risks specific to a fully unified cluster (Scenario A)

### Compliance / audit story

We operate in a **healthcare** context with a partner (Cinfa) whose
parent organisation conducts security reviews. "Two physically separated
Kubernetes clusters" is a much easier audit narrative than "one cluster
with logical isolation via namespaces, NetworkPolicies, RBAC, and
ResourceQuotas".

This is not theoretical. Cinfa's procurement processes have asked
infrastructure-shape questions in the past. Defending a unified cluster
requires explaining the controls — and proving them. Defending two
clusters is a one-line diagram.

For ~$24/mo the defensibility is not worth giving up.

### Noisy neighbour

Even with separate node pools, a single cluster shares:

- **etcd / API server** — DOKS standard control plane; throughput is
  shared between every controller, operator, and `kubectl` user across
  both envs. A flapping dev pod creating thousands of events per
  minute degrades prod's API latency.
- **CoreDNS** — unless we run separate DNS deployments, a dev DNS
  query storm hits prod resolution.
- **Conntrack table** on each node, **PID limit**, **inode pressure**
  on shared hostPath / log volumes if any.
- **ingress-nginx** — one controller serves all hostnames. A
  misconfigured dev Ingress with a bad annotation can take down the
  controller for both envs.

These are mitigable (separate ingress controllers, ResourceQuotas,
PriorityClasses), but each mitigation is operational work and a
potential bug surface.

### Upgrade risk

Today the workflow is:

1. DOKS prompts a Kubernetes minor-version upgrade.
2. We run it on **dev** and let it bake for ~1 week.
3. We monitor for breaking changes (deprecated APIs, controller
   incompatibility).
4. Then we upgrade prod.

This is a quiet but important property of having two clusters. A unified
cluster forces us to upgrade dev and prod together. We lose the
canary-by-environment.

## Why Scenario C beats Scenario B (platform in dev cluster)

Scenario B was the previous recommendation. It has been superseded by
Scenario C (dedicated droplet). The reasons:

- **Chicken-and-egg on the registry**: a Zot pod whose own image must
  be pullable for the cluster to recover. Bootstrapping from a fresh
  cluster requires a public-DockerHub mirror specifically for Zot's
  own image, which is awkward. A standalone droplet has no such
  dependency.
- **Blast radius**: a control-plane or networking incident on the dev
  cluster simultaneously kills our registry and our logs view of the
  prod cluster. Decoupling improves the asymmetry — prod can be
  observed from outside dev, dev can be observed from outside prod.
- **Audit narrative**: "platform tier on its own host with its own
  backups and IaC" is a one-line answer in healthcare procurement
  reviews, cleaner than "platform services share resources with dev
  apps".
- **K8s overhead pays for nothing here**: Zot, Loki, Caddy are 3 static
  services that don't scale, don't reschedule, and don't need rolling
  updates. The kubelet + control plane + manifests overhead is pure
  tax on these workloads. `docker compose up -d` plus a weekly
  snapshot is the right operational shape.
- **DNS isolation**: `*.platform.fagorhealthcare.com` becomes a
  dedicated zone owned by the platform repo's Terraform state.
  Accidental edits to app DNS no longer risk platform availability.

The droplet costs ~$33/mo (see [06](06-platform-tier.md) for detail).
The savings from pillar 03 (~$70/mo from cancelling AWS ES) more than
cover it; net delta vs the AWS ES status quo is **−$44/mo** while
gaining vulnerability scanning and 365-day retention.

## Cross-cluster reach — the practicalities

All "shared platform" endpoints are HTTPS over the public internet,
terminated at the platform droplet's Caddy instance. This works because:

- Both DOKS clusters and the platform droplet live in `fra1`. Latency
  is sub-ms within the DO data centre — even hairpinning out and back.
- Caddy provisions Let's Encrypt certs automatically for the
  `*.platform.fagorhealthcare.com` hosts.
- Vector → AWS ES today follows the exact same pattern (HTTPS push from
  pre cluster to a sink outside the cluster). We are not introducing a
  novel topology; we are pointing the same pattern at a closer endpoint.

Things to NOT do:

- **Do not rely on private cluster networking** (e.g. VPC peering)
  between the two DOKS clusters or between a cluster and the droplet.
  DOKS clusters do not natively share a VPC; setting it up is involved
  and undoes "physically separate" defensibility.
- **Do not host any application workload on the platform droplet.** It
  is for shared infrastructure only. Application services go in the
  DOKS clusters.

## Done when

- [x] Decision documented in this repo: Scenario C (dedicated droplet)
- [ ] Pillars 02 and 03 reference Scenario C and place their components
      on the platform droplet accordingly
- [ ] Pillar 06 (platform tier) implemented
- [ ] Cross-cluster TLS endpoints (`registry.platform.fagorhealthcare.com`,
      `logs.platform.fagorhealthcare.com`) documented in `INFRASTRUCTURE.md`
