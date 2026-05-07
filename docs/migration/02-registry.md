# Pillar 02 — Self-hosted Image Registry

Status: **proposed** | Estimated savings: **~$0/mo (gains scanning + ends hardcoded creds)** | Effort: **~3.5 days** | Risk: **medium** | Depends on: **01-rightsizing**

Replace DockerHub (`gailen/*`) with **Zot**, a CNCF-sandbox single-binary OCI
registry, backed by **DigitalOcean Spaces** (S3-compatible) for storage and
**Trivy** for built-in vulnerability scanning. The savings here are roughly
break-even — the value is in the security and operational posture, not the
bill.

## Motivation

Three problems with the current DockerHub setup:

1. **`add_tag.sh` carries a hardcoded DockerHub credential**
   (`gailen:873e27e5-…`). It is in CLAUDE.md as a known-bad smell. Rotating
   it requires touching every workflow that runs the script. A
   self-controlled registry uses standard k8s pull secrets and per-CI
   service tokens.
2. **No vulnerability scanning anywhere**. We push images, we deploy them;
   nothing in between tells us "this base image has 47 critical CVEs". Zot
   ships Trivy as a built-in extension that scans on push and updates the
   CVE DB daily.
3. **DockerHub rate limits and outages affect us**. Anonymous pulls are
   rate-limited globally; authenticated pulls have a higher but still finite
   limit. A new node joining DOKS during an incident must pull every image
   from DockerHub — a known-bad behaviour during DockerHub's periodic
   outages.

## Target architecture

```
                         GitHub Actions (CI)
                                │
                                │ docker push
                                ▼
                ┌──────────────────────────────────┐
                │   registry.fmd.fagorhealthcare   │   (or registry.k8s.gailen.net)
                │   .com (TLS via cert-manager)    │
                └──────────────┬───────────────────┘
                               │ Ingress (nginx-ingress)
                               ▼
                       ┌───────────────┐
                       │  Zot pod      │   storage backend = S3
                       │  + Trivy ext. │   ─────────────────────►  DO Spaces
                       │  Deployment   │                           "platform-registry"
                       └───────┬───────┘                           (fra1, same DC as cluster)
                               │
                               │ extension API
                               ▼
                  /v2/_zot/ext/search?cve  (consumed later by `fhctl images`)

                                                 ┌─────────────────────┐
        md-backup CronJob (extended)  ────────►  │ AWS S3 standard-IA  │
        rclone sync from Spaces                  │ DR mirror (offsite) │
                                                 └─────────────────────┘
```

### Why Zot, specifically

- **Distribution** (the upstream OCI ref impl): too bare. No scanning, no
  search API, no GUI. Would need a sidecar plus glue. Cheap, but we'd build
  what Zot already gives us.
- **Harbor**: feature-complete, but it ships ~6 components (core, jobservice,
  registry, db, redis, trivy, portal) and a Postgres dependency. Overkill
  for ~7 image repositories and a single-team operation. Operational tax is
  real.
- **Zot**: single Go binary, OCI-1.1 compliant, S3 backend native, Trivy
  built in, GUI included, open governance under CNCF Sandbox. The sweet
  spot for our scale.

### Storage: DO Spaces (`platform-registry`)

- S3-compatible API → Zot's `s3` storage driver works out of the box
- `fra1` region → same datacentre as both DOKS clusters → intra-DC pulls are
  free (no egress charges from cluster nodes)
- Lifecycle rule: nothing automatic; manifests are append-only by `<branch>.<run>`
  tag, so even abandoned branches are tiny compared to DOKS storage in general
- Estimated steady-state size: ~7 services × ~80 builds retained × ~300 MiB
  per layer (deduped) = ~5 GiB. Fits comfortably in the smallest Spaces tier.

### Backup / DR: AWS S3 standard-IA

- Extend the `md-backup` CronJob with one extra `rclone sync` step:
  `rclone sync spaces:platform-registry s3-ia:fagor-registry-mirror/`
- AWS S3 IA at ~5 GiB is ~$0.06/mo for storage + minimal request charges.
  Round to $1/mo.
- This is a true offsite, second-cloud DR copy. If DigitalOcean has a
  region-wide outage we can re-point Zot at the AWS bucket as read-only and
  keep deploys working from cached images.

### Vulnerability scanning

Zot's `extensions.search.cve` block enables Trivy CVE updates daily and
exposes findings via:

```
GET /v2/_zot/ext/search?query={CVEListForImage(...)}
```

Plumb this into a future `fhctl images cves <service>` command. Initial
target: just human-readable output. Later: a "block prod deploy if any
CRITICAL" gate in `release.yml`.

## Cost delta

| Change | Monthly delta |
|---|---|
| DockerHub Pro / paid plan canceled | **−$5 to −$10** |
| DO Spaces (`platform-registry`, ~5 GiB) | **+$5** |
| AWS S3 IA mirror (`fagor-registry-mirror`, ~5 GiB) | **+$1** |
| Zot pod compute (~512 MiB on existing dev node) | $0 (uses pillar 01 headroom) |
| **Net** | **~$0/mo** |

## Work breakdown (~3.5 days)

The bulk is the migration choreography, not the install.

### Day 1 — Stand up Zot in dev (parallel to DockerHub)

- Helm install Zot into `md-dev-cluster` using the [official chart](https://github.com/project-zot/helm-charts).
- ConfigMap: S3 driver pointing at `platform-registry`, extensions for `search`,
  `cve` (Trivy with daily refresh), `ui`, `metrics`.
- Ingress: `registry.k8s.gailen.net`, TLS issued by the existing
  `letsencrypt-prod` ClusterIssuer (HTTP-01).
- Verify push/pull manually with `docker login registry.k8s.gailen.net`,
  push a smoke image, pull from a pod via a test PSC.

### Day 2 — Cut over a pilot service

- Pick `md-backup` (lowest blast radius — runs as a CronJob, not in the
  serving path).
- Update its `cd.yaml` to push to `registry.k8s.gailen.net/md-backup` in
  parallel to DockerHub for one cycle, then DockerHub-only off.
- Add `registry.k8s.gailen.net` to `md-dockerhub-regcred` (rename the
  secret to `platform-regcred` for clarity, but keep DockerHub creds
  alongside Zot creds — the pull-secret format is a list of registries).
- Verify the pilot deploys cleanly. Roll back is `kubectl set image` to
  the DockerHub digest.

### Day 3 — Roll the rest of the services

- One `cd.yaml` at a time: `md-pwa` → `md-resi-front` → `md-resi-back` →
  `md-auth` → `md-core` (most-critical last).
- After all dev `cd.yaml`s push to Zot, update `release.yml` (Release to
  PROD) to also push to Zot. Pre cluster pulls from `registry.k8s.gailen.net`
  cross-cluster (same `fra1` datacentre, no egress).
- **Do not delete DockerHub repositories yet.** Keep them as a fallback
  read-only mirror for at least one full release cycle.

### Day 4 (half-day) — Replace `add_tag.sh`

- Replace the manifest-PUT-via-curl approach with `oras tag` against Zot.
  Zot supports the OCI distribution-spec tag operations natively, so the
  hardcoded credential goes away — CI uses a per-job service token issued
  via Zot's HTTP basic auth or, preferably, a GitHub OIDC flow if Zot's
  auth extensions are enabled.
- Extend `md-backup`'s CronJob spec to include the `rclone sync` step.
- Update `docs/INFRASTRUCTURE.md` and `docs/DEPLOYMENT.md` (in this repo)
  to reflect the new registry hostname and tag mechanics.

## Risks and gotchas

- **Chicken-and-egg on Zot itself**: a fresh DOKS cluster bootstrapping for
  the first time has no way to pull the Zot pod's image from Zot. Solution:
  Zot's *own* image stays on **public DockerHub** (`ghcr.io/project-zot/zot`
  or `gailen/zot-mirror`). Every other `gailen/*` image moves to Zot. This
  inversion is documented in `bootstrap.sh` so a laptop/CI rebuild does
  not get stuck.
- **Pull-secret confusion**: kubelets currently use `md-dockerhub-regcred`.
  Adding the Zot endpoint requires updating *every* Deployment's
  `imagePullSecrets`. Easier: rename the secret to `platform-regcred`,
  embed both endpoints, and set it as `imagePullSecrets` on the default
  `ServiceAccount` so new manifests inherit it.
- **NetworkPolicy**: if/when we adopt NetworkPolicies, the pre cluster's
  egress to `registry.k8s.gailen.net` (in dev cluster) must be allowed
  explicitly. For now there are no NPs in place.
- **The hardcoded DockerHub credential lives on** until step 4 above. Do
  not push the new docs claiming "rotated" until `add_tag.sh` is gone.
- **TLS for the registry**: Let's Encrypt rate limits are 50 certs/week per
  registered domain. We are well below this, but if the issuance flapps
  during initial setup we can hit the limit. The `letsencrypt-prod`
  ClusterIssuer already runs on dev cluster, so just reuse it.
- **`cinfa-adhoc-cert` is not affected by this pillar.** No ingress entries
  for `*.cinfa.com` change. (Re-flagging because the registry ingress also
  lives in the dev cluster's NGINX controller — accidental config bleeds
  are the failure mode to watch for.)

## Integration with `fhctl`

Phase H of the `fhctl` design (see [`../fhctl-DESIGN.md`](../fhctl-DESIGN.md))
established the integrations pattern. This pillar adds:

- New module: `internal/registry/zot.go` implementing the same interface
  as the existing `internal/registry/dockerhub.go`. Pluggable via a
  `--registry zot|dockerhub` flag, defaulting to Zot once migration is
  complete.
- New command: `fhctl registry login` reusing the secrets/integrations
  table the same way `fhctl es login` does today.
- New command: `fhctl images cves <service>` consuming Zot's
  `/v2/_zot/ext/search` API.

These are follow-on tickets, not blockers for the migration itself.

## Done when

- [ ] All `gailen/*` images mirrored to Zot for at least one release cycle
- [ ] All `cd.yaml` and `release.yml` workflows push to Zot
- [ ] `add_tag.sh` rewritten to use `oras` against Zot, hardcoded DockerHub
      credential removed from the codebase
- [ ] `md-backup` extended with the `rclone sync` step, verified once
- [ ] DockerHub paid plan downgraded or canceled
- [ ] Trivy scan results visible for every active image
- [ ] `INFRASTRUCTURE.md` and `DEPLOYMENT.md` in this repo updated
