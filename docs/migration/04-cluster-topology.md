# Pillar 04 — Cluster Topology

Status: **proposed (decision needed before pillars 02 / 03 land)** | Estimated savings: **−$0 to −$24/mo** | Effort: **architectural decision; minimal direct work** | Risk: **medium (audit/compliance, blast radius)** | Depends on: **none** (but informs 02 and 03)

Should we collapse `md-dev-cluster` and `md-pre-cluster` into a single DOKS
cluster with namespace-based env separation? This pillar exists to make the
trade-off explicit and answer the question on paper before action.

**Recommended outcome (TL;DR):** keep the two **app** clusters separate.
Consolidate the **platform** services that pillars 02 and 03 introduce
(Zot, Loki, Grafana, optionally cert-manager) into one place — the **dev**
cluster — instead of running parallel platform stacks per environment.

## The question

Two scenarios are on the table:

### Scenario A — Fully unified single cluster

- One DOKS cluster, two namespaces (`dev-0`, `pre`).
- Single NGINX ingress controller, single load balancer.
- Apps share node pool(s).

### Scenario B — Split: keep app clusters, consolidate platform

- App clusters stay as-is: `md-dev-cluster` for dev workloads, `md-pre-cluster` for prod.
- New platform components (registry, Loki, Grafana, possibly a shared cert-manager) live in **one** of the existing clusters — the dev one — and are consumed cross-cluster by the prod one.
- No fully separate "platform cluster" (rejected on cost — see [05-not-doing.md](05-not-doing.md)).

## Honest cost analysis

The savings cap is much smaller than it looks at first glance.

### If pools were fully shared (Scenario A)

| Saving source | Best case |
|---|---|
| Drop one set of node pools | up to $48/mo if dev's nodes vanish into spare capacity on pre's pool |
| Drop one HTTPS load balancer | $12/mo |
| Drop one MQTT load balancer | $12/mo (only if MQTT can share with HTTPS LB — currently not configured to) |
| Drop one managed Postgres? | unlikely — see below |
| **Theoretical max** | **~$72/mo** |

But: production should not co-tenant with dev on the same node pool. The
production node pool is sized for prod traffic with a margin; adding dev's
load means either a bigger pool (negating savings) or accepting that a
runaway dev pod starves prod. In practice we'd run **separate node pools per
env** even in Scenario A, so:

### If we keep separate node pools (realistic Scenario A)

| Saving source | Realistic |
|---|---|
| Single control plane | **$0** (DOKS standard CP is free anyway) |
| One HTTPS LB consolidated | **$12/mo** |
| One MQTT LB consolidated | **$12/mo** (if reachable) |
| Postgres consolidation | **$0** — already one DO Postgres account; both pools live there |
| **Realistic max** | **~$24/mo** |

### Scenario B (recommended)

| Saving source | Realistic |
|---|---|
| Platform services don't duplicate per-env (Zot, Loki, Grafana, cert-manager) | implicit in pillars 02 and 03, already counted there |
| LBs | **$0** — both clusters keep their LBs |
| **Direct topology savings** | **~$0** |

So: **the topology change buys at most $24/mo on top of pillars 01–03**,
and only if we accept real risks documented below.

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

### Blast radius of platform services

If platform services (Zot, Loki) live in the *same* cluster as workloads,
a control-plane incident takes down both at once. Pillar B's
recommendation places platform services in **dev**, where:

- Loss of registry pulls during an incident only affects new pod starts,
  not running pods. Production keeps running while we fix dev.
- Loss of logging is degraded observability, not a service outage.
- Dev cluster failures don't take prod down — the inverse holds too.

This is the right asymmetry: prod must keep running even when dev is
broken, but dev can tolerate prod-side issues.

## Recommendation

**Keep `md-dev-cluster` and `md-pre-cluster` separate.** Park platform
services in `md-dev-cluster`. Specifically:

- **Zot registry** (pillar 02) — runs in dev cluster, exposed at
  `registry.k8s.gailen.net`. Pre cluster's kubelets pull from it via
  DNS. Same `fra1` datacentre → no cross-cluster egress charges.
- **Loki + Grafana** (pillar 03) — run in dev cluster, exposed at
  `logs.k8s.gailen.net`. Vector in pre cluster pushes to it via TLS
  ingress, the same way it pushes to AWS ES today.
- **cert-manager** — stays per-cluster. Consolidating it cross-cluster
  is more trouble than it's worth and the current setup works.

## Cross-cluster reach — the practicalities

All three "shared platform" endpoints (registry, logs, future Grafana)
are HTTPS over the public internet, terminated at the dev cluster's
ingress controller. This works because:

- Both clusters live in `fra1`. Latency is sub-ms within the DO data
  centre — even hairpinning out and back.
- TLS is already provisioned for `*.k8s.gailen.net` via cert-manager.
- Vector → AWS ES today follows the exact same pattern (HTTPS push from
  pre cluster to a sink outside the cluster). We are not introducing a
  novel topology; we are pointing the same pattern at a closer endpoint.

Things to NOT do:

- **Do not rely on private cluster networking** (e.g. VPC peering)
  between the two DOKS clusters. DOKS clusters do not natively share a
  VPC; setting it up is involved and undoes "physically separate"
  defensibility.
- **Do not put production on dev's NGINX controller**. They stay
  separate. Only the *content* (logs, image pulls) crosses.

## Decision: who, when, by what

This pillar is the only one that needs an architectural sign-off rather
than just engineering work. Recommendation: confirm Scenario B with
Jorge before pillar 02 or 03 starts, since both place new components
that will be hard to relocate later.

## Done when

- [ ] Decision documented in this repo (this file, "Recommendation"
      section): Scenario B accepted
- [ ] Pillars 02 and 03 reference Scenario B and place their components
      in `md-dev-cluster` accordingly
- [ ] Cross-cluster TLS endpoints (`registry.k8s.gailen.net`,
      `logs.k8s.gailen.net`) documented in `INFRASTRUCTURE.md`
