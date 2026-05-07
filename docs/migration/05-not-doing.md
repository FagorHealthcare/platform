# Pillar 05 — Things explicitly rejected

Status: **decisions, not work** | Estimated savings: **n/a** | Effort: **0** | Risk: **n/a** | Depends on: **none**

This file records the alternatives we considered and chose not to
pursue, with the reasoning. It exists so that the next time someone
(possibly future-us) suggests one of these, we have a written record of
the trade-off rather than re-litigating from scratch.

## A. Migrate DOKS → self-managed k3s on droplets

**The pitch**: "DOKS managed Kubernetes is paying for control plane
convenience. Run k3s on raw droplets, save the control plane and the
DO managed LB tax, gain control."

**Why we are not doing it**:

- **DOKS standard control plane is free.** There is nothing to save on
  the control plane line. (HA control plane is $40/mo/cluster, but we
  don't use HA.)
- **The actual saving is just the DO managed Load Balancers** ($12/mo
  each × 4 = ~$48/mo). To get there we'd:
  - run our own ingress with public IPs on droplets,
  - manage our own kube-proxy / cloud-controller-manager replacement,
  - lose DOKS's auto-upgrades,
  - lose the integration that lets `Service: type=LoadBalancer`
    provision a DO LB declaratively,
  - take operational responsibility for kubelet patches, etcd backups,
    and CoreDNS upgrades on every node.
- **At our scale, one operational incident wipes out a year of
  savings.** A four-hour weekend outage to recover an etcd quorum
  costs more in stress and trust than $48/mo × 12 ever saves.
- **Audit/compliance optics**: "managed Kubernetes by a tier-1 cloud
  provider" reads better than "self-managed k3s on rented VMs" in any
  due-diligence questionnaire we've seen from healthcare-adjacent
  partners.

**Verdict**: **rejected**. Bad cost/benefit at this scale.

## B. Use DigitalOcean Container Registry (the managed product)

**The pitch**: "Skip self-hosting Zot. DO has a managed Container
Registry product, ~$5–20/mo, integrates natively with DOKS pull
secrets, no operational burden."

**Why we are not doing it**:

- **Cost**: DOCR Basic is ~$5/mo (capped at 5 GiB), comparable to
  pillar 02's Spaces cost. DOCR Pro is ~$20/mo for a higher cap. But
  with pillar 06 in place, the platform droplet *already exists* for
  Loki — adding Zot to its compose stack is **$0 marginal**. DOCR is
  strictly more expensive in our final architecture.
- **No vulnerability scanning at the registry edge.** DOCR does not
  ship Trivy or any built-in scanner. Achieving vuln scanning would
  require a separate scanning pipeline. Zot's Trivy extension solves
  this in one config block.
- **No native S3 backup story.** A core design point of pillar 02 is
  that the registry's content lands in a Spaces bucket we control,
  and gets mirrored offsite by an extension of the existing
  `md-backup` CronJob to AWS S3. DOCR's data lives in DO's tenant
  infrastructure with no exfiltration path beyond
  `doctl registry export`.
- **`add_tag.sh`'s tag-rewriting trick (manifest PUT under a new tag,
  no re-push)** is a generic OCI distribution-spec operation. Zot
  supports it; DOCR's tag handling is opaque. Worth verifying before
  using DOCR if we ever revisit, but not free.

**Verdict**: **rejected**. Loses on scanning + backup control, and
costs more in net than the chosen architecture given the platform
droplet already exists for Loki.

## C. Run Loki separately in each cluster (no cross-cluster ingest)

**The pitch**: "Avoid cross-cluster TLS ingest. Run a Loki instance
in *each* cluster, each writing to its own object-storage backend."

**Why we are not doing it**:

- **Two operational stacks, not one.** Two Loki versions to keep in
  sync, two retention configs, two compactor jobs, two Grafana
  datasources to keep wired.
- **No unified search.** An incident that touches both dev and prod
  (e.g. the same misconfigured Vector regex) needs to be debugged
  twice in two UIs.
- **No cost saving.** The Spaces bucket costs the same whether it's
  one big bucket or two smaller ones; the Loki pod has the same
  baseline footprint either way; we'd actually pay slightly more for
  the second PVC.
- **Cross-cluster ingest is not novel.** Vector already pushes from
  both clusters to AWS ES (outside both clusters) over TLS. Pointing
  the same flow at our own Loki at `logs.k8s.gailen.net` is the same
  shape with a closer endpoint.

**Verdict**: **rejected**. Doubles operational surface for no gain.

## D. Fully unified single cluster (collapse dev + pre)

See [04-cluster-topology.md](04-cluster-topology.md) for the long
analysis. Short version: best-case savings ~$24/mo, real costs include
audit narrative, noisy-neighbour risk, lost canary-by-environment for
upgrades, shared-ingress blast radius.

**Verdict**: **rejected**. Wrong cost/benefit; the recommendation is
"keep app clusters separate, host platform services on a dedicated
droplet" — see [04-cluster-topology.md](04-cluster-topology.md) and
[06-platform-tier.md](06-platform-tier.md).

## E. Drop Vector, push directly from app pods to Loki

**The pitch**: "Loki has language-agnostic HTTP push. Skip the Vector
DaemonSet. Each Quarkus service ships logs to Loki directly with
e.g. `loki-logback-appender`."

**Why we are not doing it**:

- **All the parsing logic is in Vector.** The `parse_nginx_log`
  transform, the JSON merge, the ad-hoc
  `:U…:B…:T…:S…:P…:` regex extraction — none of that exists in app
  code. Pushing it into each service multiplies the surface that has
  to know about log-line shape.
- **Vector also reads NGINX, NodeRed, n8n, kube-events stdout**.
  Removing Vector means losing visibility for everything that is not
  a Quarkus service.
- **The current Vector setup works.** Pillar 03's whole pitch is
  "swap one sink, keep everything else identical". Throwing out
  Vector turns a 1-day pillar into a multi-week refactor across
  every service.

**Verdict**: **rejected**. We migrate the sink, not the producer.

## F. Host platform services in the dev cluster (the original "Scenario B")

**The pitch**: "Run Zot, Loki, Grafana as Helm charts in the existing
`md-dev-cluster`. No new host to operate. Pre cluster reaches them
cross-cluster via TLS ingress at `*.k8s.gailen.net`."

This was the original recommendation in pillar 04, before being
superseded by Scenario C (dedicated platform droplet, see
[06-platform-tier.md](06-platform-tier.md)).

**Why we are not doing it**:

- **Chicken-and-egg on the registry.** A Zot pod in the dev cluster
  whose image is pulled by the dev cluster's kubelets is fragile
  during cluster bootstrap and incident recovery. A standalone host
  has no such dependency.
- **Blast radius**: a control-plane or networking incident in dev
  simultaneously kills our registry and our log-query path for prod.
  A dedicated host decouples the failure domains — prod can be
  observed even when dev is on fire, and vice versa.
- **Audit narrative**: "platform tier on its own host with its own
  backups and IaC" is a one-line answer in healthcare procurement
  reviews. "Platform services share resources with dev apps" needs
  explaining.
- **K8s overhead pays for nothing here.** Zot, Loki, Caddy are 3
  static services that don't scale, don't reschedule, and don't need
  rolling updates. The kubelet + control plane + manifests overhead
  is pure tax. `docker compose up -d` plus a weekly snapshot is the
  right operational shape.
- **DNS isolation**: a dedicated `*.platform.fmd.fagorhealthcare.com`
  zone owned by the platform repo's Terraform state means accidental
  edits to app DNS no longer affect platform availability.

**Verdict**: **rejected**. The droplet (pillar 06) is cleaner on
every axis except "no new host to operate", and the operational cost
of a single Debian box with `docker compose` and `unattended-upgrades`
is genuinely small.

## G. Use Postgres for everything (drop managed DBs to one tier)

**The pitch**: "Two managed Postgres clusters cost $75/mo combined.
Could we run a single self-managed Postgres on a $24 droplet for
both dev and prod?"

**Why we are not doing it**:

- **Healthcare data on a self-managed Postgres without DO's
  PITR/snapshots is a regulatory risk** we don't want to take on for
  ~$50/mo savings.
- **Failover and patch story**: DO managed Postgres handles minor
  upgrades and failover automatically. Self-managed means us, at
  3am, with `pg_basebackup` and tears.
- **DO Postgres has a "shared cluster" option** at lower tiers that
  could host both pools cheaper, but the dev cluster's `db-s-1vcpu-1gb`
  is already the smallest tier. There's no smaller knob to turn.

**Verdict**: **rejected**. Wrong tier of risk for a small saving.

## When to revisit these

Triggers that would justify reconsidering each:

| Rejected option | Trigger to revisit |
|---|---|
| A — k3s on droplets | DOKS pricing changes by ≥2× *or* we hit DOKS limitations the managed plane can't address |
| B — DOCR managed | Zot operationally fails (e.g. Trivy DB updates breaking too often) *or* DOCR adds Trivy + S3 export |
| C — Loki per cluster | A regulatory finding requires logs to never leave their cluster of origin |
| D — Single cluster | Cinfa or another partner explicitly accepts logical isolation, *and* we have ResourceQuotas / NetworkPolicy / PriorityClass infrastructure already in place for unrelated reasons |
| E — Direct push to Loki | Vector is deprecated or its operational cost grows materially |
| F — Platform in dev cluster | The platform droplet operationally fails (e.g. repeated `unattended-upgrades` breakage) *and* we add a third DOKS cluster for unrelated reasons |
| G — Self-managed Postgres | DO managed Postgres pricing changes by ≥2× *or* we hit a DO Postgres feature limit (e.g. logical replication shape we can't get) |

If you are reading this because you are about to revisit one of these,
note your reasoning in the relevant pillar file before acting.
