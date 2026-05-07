# Pillar 01 — Rightsizing

Status: **proposed** | Estimated savings: **−$54/mo (~€50)** | Effort: **~1h** | Risk: **low** | Depends on: **none**

The cheapest, most boring, most reversible pillar. Almost entirely
`kubectl scale` and DOKS node-pool resizes — no new components, no
migration steps. Worth doing first because it (a) starts saving money
immediately and (b) creates the memory headroom the later pillars need.

## Motivation

The two clusters are not currently sized for the workload they run.

- **Dev cluster (`md-dev-cluster`)**: 4× `s-1vcpu-2gb`. Memory utilisation
  is ~81% across the pool. Most services run with `replicas: 2` purely as
  a copy of the production manifests; dev does not need HA. Dropping to
  `replicas: 1` per service drops memory pressure to ~50%, leaving
  ~512 MiB headroom on each node — directly useful for pillars 02 (Zot
  registry) and 03 (Loki) when they land.
- **Pre cluster (`md-pre-cluster`)**: 3× `c-2` CPU-optimised nodes
  ($42/node = $126/mo). CPU utilisation sits at ~3%; the workload is
  bound by memory and I/O, not CPU. Three `s-2vcpu-4gb` general-purpose
  nodes ($24/node = $72/mo) provide more total RAM (12 GiB vs 12 GiB —
  same memory, half the CPU we don't use, and almost half the cost).

## Target architecture

### Dev cluster

| Resource | From | To | Rationale |
|---|---|---|---|
| `md-core` replicas | 2 | 1 | dev has no HA requirement |
| `md-auth` replicas | 2 | 1 | dev has no HA requirement |
| `md-resi-back` replicas | 2 | 1 | dev has no HA requirement |
| `md-pwa` replicas | 2 | 1 | dev has no HA requirement |
| `md-resi-front` replicas | 2 | 1 | dev has no HA requirement |
| Node pool | 4× `s-1vcpu-2gb` | unchanged (option: 2× `s-2vcpu-4gb`) | see below |

Optional dev consolidation: 4× `s-1vcpu-2gb` (4 vCPU / 8 GiB total) →
2× `s-2vcpu-4gb` (4 vCPU / 8 GiB total) — same total cost, fewer
kubelets to babysit, more memory headroom per node, less scheduling
fragmentation. Net cost change: zero. Operational benefit: real but
small. Skip if it complicates pillar 02/03's pod scheduling.

### Pre cluster

| Resource | From | To | Rationale |
|---|---|---|---|
| Node pool | 3× `c-2` ($42/ea) | 3× `s-2vcpu-4gb` ($24/ea) | CPU at 3%, paying for compute that idles |
| Replicas | unchanged | unchanged | production keeps HA |

Same vCPU count (6), same total RAM (12 GiB), $54/mo cheaper.

## Cost delta

| Change | Monthly delta |
|---|---|
| Dev replicas 2→1 (5 services) | $0 (same nodes) |
| Pre node pool `c-2` → `s-2vcpu-4gb` | **−$54** |
| Optional dev pool consolidation | $0 |
| **Total** | **−$54/mo** |

## Work breakdown (~1 hour)

1. **Dev replica reduction** (15 min): edit `replicas: 1` in
   `k8s/environments/dev-0/*-dep.yaml` for the 5 services, commit and
   push the `k8s` repo, `kubectl apply -k environments/dev-0/`. Verify
   `kubectl get pods` shows one pod per service, all Ready.
2. **Pre node-pool resize** (30 min): in DigitalOcean console (or
   `doctl kubernetes cluster node-pool create` then delete the old one),
   create a new pool of 3× `s-2vcpu-4gb`. Cordon and drain the old
   `c-2` nodes one at a time (`kubectl drain --ignore-daemonsets
   --delete-emptydir-data`). When all pods have rescheduled and old
   nodes are empty, delete the old pool.
3. **Verify** (15 min): `kubectl top nodes`, `kubectl top pods`, hit
   `/health/<svc>` endpoints, watch Logtail/AWS ES for any error spike.

## Risks and gotchas

- **Single-replica dev means a single pod restart causes a ~30 s outage**
  on the affected dev service. Acceptable — dev is non-customer-facing.
- **Node drains during pre resize move pods around**. Production traffic
  briefly serves from fewer replicas during each drain. Mitigate by:
  doing the drain off-hours, draining one node at a time, watching
  `kubectl get endpoints` to confirm `md-core` keeps ≥2 ready endpoints
  throughout. If a service has only `replicas: 2`, this is a tight margin
  — consider temporarily bumping to 3 during the migration window.
- **The PDB story**: there are currently no `PodDisruptionBudget`s
  defined. The drain will not be blocked by missing PDBs, but adding a
  basic `minAvailable: 1` PDB before the resize is a cheap safety net.
- **Stateful workloads** (NodeRed, n8n) use PVCs. A PVC bound to a
  zone-specific volume cannot move between availability zones. DOKS
  default node pool is single-AZ in `fra1`; verify the new pool stays
  in the same AZ as the old one or those StatefulSets will go pending.
- **Reversibility**: the entire pillar is `kubectl scale` and a node-pool
  swap. If anything regresses, the old node pool can be re-created in
  ~5 minutes. Keep the old pool alive (cordoned, drained) for 24 h
  before deleting.

## Why this unblocks pillar 02

Zot + Trivy CVE database fits in ~512 MiB. Once dev is at `replicas: 1`,
that headroom is freely available without scheduling pressure.
Otherwise pillar 02 would need to add a node first, eating its own
savings.

## Done when

- [ ] All dev deployments at `replicas: 1`, all pods Ready
- [ ] `kubectl top nodes` on dev shows memory < 60%
- [ ] Pre node pool is `s-2vcpu-4gb`, all pods rescheduled, no events
- [ ] Old `c-2` pool deleted from DOKS
- [ ] DO billing console reflects the new node SKUs on the next cycle
