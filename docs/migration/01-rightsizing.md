# Pillar 01 — Rightsizing

Status: **proposed** | Estimated savings: **−$54/mo (~€50)** | Effort: **~1h** | Risk: **low** | Depends on: **none**

The cheapest, most boring, most reversible pillar. Almost entirely
`kubectl scale` and DOKS node-pool resizes — no new components, no
migration steps. **Standalone**: this pillar saves money on its own
without depending on, or being a prerequisite for, any of the others.
It is worth doing first only because the savings start immediately and
the work is reversible in minutes.

## Motivation

The two clusters are not currently sized for the workload they run.

- **Dev cluster (`md-dev-cluster`)**: 4× `s-1vcpu-2gb`. Memory utilisation
  is ~81% across the pool. Most services run with `replicas: 2` purely as
  a copy of the production manifests; dev does not need HA. Dropping to
  `replicas: 1` per service drops memory pressure to ~50% — useful for
  dev's own ergonomics (less eviction risk under build-time spikes,
  cheaper local testing of resource-heavy operations). Note that under
  the migration plan, platform services (Zot, Loki) live on a dedicated
  droplet (see [06-platform-tier.md](06-platform-tier.md)), **not** in
  the dev cluster — so this rightsizing does not unblock any other
  pillar; it is standalone operational hygiene.
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
small. Skip if it complicates the existing application workload's
scheduling (which it shouldn't — same 4 vCPU / 8 GiB total, just
fewer scheduling boundaries).

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

## Relationship to other pillars

**None.** This pillar saves money on its own and does not unblock
or block anything else. Earlier drafts of this plan considered hosting
Zot and Loki inside the dev cluster, in which case dev's memory
headroom would have been load-bearing. That design was rejected in
favour of a dedicated platform droplet (see
[04-cluster-topology.md](04-cluster-topology.md) and
[06-platform-tier.md](06-platform-tier.md)). Rightsizing is now purely
about not paying for compute we don't use.

## Dev rehearsal — what actually happened (2026-05-07)

The dev half of this pillar ran end-to-end. Captured here so the pre
half is calibrated against measured behaviour, not theory. **Total
elapsed time: ~30 minutes** from `node-pool create` to old-pool
deletion. Zero application impact for the 5 Deployments. ~100 s
downtime for each StatefulSet during volume remount.

### Sequence as executed

1. **PDBs added in `base/pdbs.yaml`** (new file, 5 entries with
   `minAvailable: 1`, only for the Deployments — StatefulSets `md-n8n`
   and `md-node-red` deliberately excluded since they run with
   `replicas: 1` and a PDB would block all drains forever).
   Committed to `main` of the `k8s` repo. Applied to dev via
   `kubectl --context=do-fra1-md-dev-cluster apply -k environments/dev-0/`.
2. **`apply -k` triggered an unintended-but-harmless side effect**:
   ConfigMap regeneration changed the configmap hash, which propagated
   to the Deployment specs and triggered rolling updates of `md-core`
   and `md-resi-back`. Both rolled cleanly to the new pool **before
   any drain** — they migrated for free. Net positive but worth
   anticipating in pre.
3. **Fase 1** — `doctl kubernetes cluster node-pool create … --size
   s-2vcpu-4gb --count 2`. Pool ID returned in ~5 s; both nodes Ready
   in ~2 min.
4. **Fase 2** — `kubectl cordon` on all 4 old nodes. Idempotent.
5. **Fase 3** — `kubectl drain` one node at a time, in order chosen
   to defer the StatefulSet node to last. Each drain returned in
   < 30 s for nodes hosting only Deployments + DaemonSets.
6. **PDB demonstration**: when draining `md-dev-basic-5w3nk`,
   `md-pwa` had its 2 replicas on that single node. The drain
   evicted one immediately, then for the second:
   ```
   error when evicting pods/"md-pwa-...": Cannot evict pod as
   it would violate the pod's disruption budget. (will retry after 5s)
   ```
   The eviction queued for ~30 s until the new replica was Ready in
   the new pool, then completed. **This is the exact scenario the
   PDB was added for.** Without the PDB, both replicas would have
   been evicted simultaneously → md-pwa unavailable until reschedule.
7. **StatefulSet drain** — final node `md-dev-basic-5w3ni`. Volume
   detach/attach pattern observed:
   - t+0 s: drain starts, both SS pods evicted.
   - t+0 s: scheduler assigns both pods to `md-dev-v2-3nih37`.
   - t+1 s: `FailedAttachVolume` warning — "Multi-Attach error for
     volume … Volume is already exclusively attached to one node".
     This is DO Block Storage's normal release latency.
   - t+~20 s: detach completes, attach to new node succeeds.
   - **md-node-red ready at t+40 s**.
   - **md-n8n ready at t+100 s** (~60 s longer — random difference,
     probably internal n8n DB schema check on startup).
8. **Fase 4** — `doctl kubernetes cluster node-pool delete`. Returns
   immediately; full droplet teardown takes ~1 min. **`doctl
   node-pool list` returned stale data for ~30 s after deletion**
   (showed the deleted pool with its 4 nodes); kubectl was the
   source of truth (correctly showed only the 2 new nodes).

### What surprised us

| Observation | Implication for pre |
|---|---|
| `apply -k` triggered ConfigMap-driven rolling restarts on `md-core` and `md-resi-back` | In pre, this means a brief restart of every service whose ConfigMap content changes between applies. Plan to apply the PDBs **separately and earlier** than the resize — ideally hours or a day before — so the rolling restart noise doesn't overlap with the drain noise. |
| `Multi-Attach error` for ~20 s during PV detach is **silent** to the eviction status | Operator sees `ContainerCreating` but not the underlying cause unless they `kubectl describe pod`. For pre, mention this in the runbook so nobody panics during the wait. |
| md-n8n took ~100 s to be Ready vs ~40 s for md-node-red | Pre's SS pods may take longer than 100 s. **Budget 3 minutes per StatefulSet** for the runbook, not 30-90 s. |
| `doctl node-pool list` cache lag after delete | Trust kubectl, not doctl, for "is the old pool gone?". |
| All 14 app pods landed in pool nuevo with no scheduling failures | Confirms zone alignment between pools is fine in this DOKS cluster. Worth re-verifying for pre but the pattern is reproducible. |

### Numbers worth carrying to pre

- **Pool create → Ready**: 2 min
- **Drain time per non-SS node**: < 30 s
- **Drain time for SS node (incl. volume remount + container start)**: ~100 s
- **Pool delete settle time**: ~1 min (visible in DO billing) but ~30 s
  cache lag in doctl
- **Total wall time, dev cluster, end-to-end**: 30 min
- **Application unavailability for Deployments**: 0 (PDBs held)
- **Application unavailability for SS**: ~100 s each, simultaneous

## Pre-specific runbook (calibrated)

This is the runbook to follow when resizing the **`md-pre-cluster`**
node pool from `c-2` ($42 × 3 = $126) to `s-2vcpu-4gb`
($24 × 3 = $72), saving $54/mo. It assumes pillar 01's dev half is
already done.

### Pre-flight differences vs dev (one-time check)

```bash
# 1. Confirm context (CRITICAL)
kubectl config current-context  # MUST be: do-fra1-md-pre-cluster

# 2. Confirm pre cluster ID + node pool ID
doctl kubernetes cluster list
doctl kubernetes cluster node-pool list <pre-cluster-id>

# 3. Verify zone alignment of existing PVs (pre has its own SS PVCs)
kubectl get pv -o custom-columns=NAME:.metadata.name,ZONE:.metadata.labels."topology\.kubernetes\.io/zone",CLAIM:.spec.claimRef.name

# 4. Confirm PDBs already in place (committed in the dev rehearsal)
kubectl get pdb -n default
# Expected: 5 PDBs, all ALLOWED-DISRUPTIONS=1 (else applications are
# already in distress; do NOT proceed)

# 5. Inventory of services + replica counts on pre
kubectl get deploy,statefulset -n default
```

### Pre-specific risks (not present in dev)

| Risk | Mitigation |
|---|---|
| **Real user traffic** on `md-core`, `md-pwa`, `md-resi-front`, `md-auth` | Schedule the resize for off-hours (weekend, Spanish night). PDBs ensure ≥1 ready pod per service throughout, so no full outage; brief 50% capacity windows are acceptable. |
| **`md-n8n` and `md-node-red` SS downtime** ~100 s each, simultaneous if on same node | If pre's n8n is part of any production workflow (Twilio webhook, sync trigger), this is **a real outage** of those workflows for ~100 s. Verify with the team whether pre n8n serves real traffic; if yes, schedule the SS-node drain for a window when n8n traffic is quiet. |
| **`ingress-nginx-controller` is single-replica** (was evicted in dev) | In dev a brief 502 window doesn't matter. In pre this means **public traffic returns 502 for the ~10 s** the controller takes to come up on the new node. **Mitigation: scale the ingress controller to `replicas: 2` with `minAvailable: 1` PDB** *before* the resize. Add to a follow-on PR or do as part of pre prep. |
| **`apply -k` ConfigMap-rolling-restart side effect** would restart services on top of the resize traffic | **Apply PDBs to pre AT LEAST 1 day before the resize**. Run `kubectl apply -k environments/pre/` on a calm day, watch for rollouts to finish, then proceed with the resize on a separate day. |
| **`cinfa-adhoc-cert` TLS secret** must NOT be touched | Verify `kubectl apply -k environments/pre/` does not include that secret in its rendered output. If it does, **stop and consult `k8s/CLAUDE.md` cert-manager runbook before proceeding**. |
| **Cinfa Salesforce integration** queries `medicaldispenser-sw.cinfa.com` (pre's ingress) | Brief ingress unavailability could cause Cinfa retries/alerts. Coordinate timing or pre-warn Cinfa contact if the window matters. |

### Pre-flight checklist (1 day before)

- [ ] PDBs applied to pre (`kubectl apply -k environments/pre/`)
- [ ] `kubectl get pdb -n default` shows the 5 PDBs with
      `ALLOWED-DISRUPTIONS=1`
- [ ] `kubectl rollout status` clean for all Deployments after the
      apply (no in-flight rollouts when the resize starts)
- [ ] Off-hours window scheduled (weekend / late evening Madrid time)
- [ ] Cinfa contact pre-warned if window crosses business hours
- [ ] On-call alerted; team member available as second pair of eyes

### The resize itself (T-day)

Same structure as dev — only the cluster ID, node pool ID, and node
names differ.

```bash
PRE_CLUSTER=8e4f0074-8cc3-46d8-8ccb-88e0ac208ba9
PRE_OLD_POOL=8d9150e8-5c01-4267-a991-65617c486ef8  # md-pre, 3× c-2
NEW_POOL_NAME=md-pre-v2

# Fase 1 — create new pool
doctl kubernetes cluster node-pool create $PRE_CLUSTER \
  --name $NEW_POOL_NAME --size s-2vcpu-4gb --count 3 --tag k8s:worker

# Wait until new nodes Ready (~2 min)
kubectl --context=do-fra1-md-pre-cluster get nodes -w
# Ctrl-C when 3 nodes labeled $NEW_POOL_NAME-* show Ready

# Fase 2 — cordon all 3 old nodes
kubectl --context=do-fra1-md-pre-cluster cordon \
  md-pre-3n7c3t md-pre-3n7c3l md-pre-3n7c32   # use real names from get nodes

# Fase 3 — drain one at a time, SS-hosting node LAST
for n in md-pre-3n7c3t md-pre-3n7c3l md-pre-3n7c32; do
  echo "=== draining $n ==="
  kubectl --context=do-fra1-md-pre-cluster drain $n \
    --ignore-daemonsets --delete-emptydir-data --timeout=300s
  echo "verify endpoints stay >=1:"
  kubectl --context=do-fra1-md-pre-cluster get endpoints -n default \
    | awk 'NR==1 || /^md-/'
  echo "Press Enter when ready to drain the next node..."
  read
done

# Fase 4 — verify and delete old pool
kubectl --context=do-fra1-md-pre-cluster get nodes
kubectl --context=do-fra1-md-pre-cluster top nodes
# Hit each service's /q/health from outside the cluster:
fhctl health --env pre --json | jq '.services[] | select(.status != "UP")'
# Expected: empty array

doctl kubernetes cluster node-pool delete $PRE_CLUSTER $PRE_OLD_POOL --force
```

### What "rollback" looks like at each phase

| Phase | If it goes wrong | Recovery |
|---|---|---|
| Fase 1 (pool create) | new pool fails to provision | `doctl … node-pool delete <new-pool-id>`. State unchanged. |
| Fase 2 (cordon) | nothing to go wrong | `kubectl uncordon` reverses. |
| Fase 3 (drain) | a drain blocks > 5 min, or a service goes 0/N ready | `kubectl uncordon md-pre-XXXX`. Pods that were evicted will reschedule on whichever node has space; uncordoning the original node lets the scheduler use it again. **Do not delete the old pool until every service is verified healthy.** |
| Fase 4 (delete pool) | already past the no-return point | If the new pool is unhealthy by now, recover via `doctl … node-pool create` matching the old spec (3× c-2). Cost: a few minutes of $42×3 you didn't intend to spend. |

### Done when

- [ ] All 5 Deployments + 2 StatefulSets Running on the new pool
- [ ] `kubectl get nodes` shows only the new pool
- [ ] `kubectl top nodes` on pre shows healthy memory/CPU
- [ ] `fhctl health --env pre --json` exits 0 (every service UP)
- [ ] Old `c-2` pool deleted in DOKS, droplets gone in `doctl
      compute droplet list`
- [ ] DO billing console reflects the new node SKU on next billing
      cycle (verify ~24 h later)
- [ ] Monthly run-rate dropped by $54 (effectively €50)
