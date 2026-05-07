# Pillar 02 — Self-hosted Image Registry

Status: **proposed** | Estimated savings: **~$0/mo** (gains scanning + ends hardcoded creds) | Effort: **~1 day** | Risk: **medium** | Depends on: **[06-platform-tier.md](06-platform-tier.md)** (registry runs on the platform droplet)

Replace DockerHub (`gailen/*`) with **Zot**, a CNCF-sandbox single-binary
OCI registry, backed by **DigitalOcean Spaces** (S3-compatible) for
storage and **Trivy** for built-in vulnerability scanning. Zot runs as a
service in the platform-tier `docker compose` stack on a dedicated
droplet (see [06-platform-tier.md](06-platform-tier.md)). The savings
here are roughly break-even — the value is in the security and
operational posture, not the bill.

## Motivation

Three problems with the current DockerHub setup:

1. **`add_tag.sh` carries a hardcoded DockerHub credential**
   (`gailen:873e27e5-…`). It is in CLAUDE.md as a known-bad smell.
   Rotating it requires touching every workflow that runs the script.
   A self-controlled registry uses standard k8s pull secrets and per-CI
   service tokens.
2. **No vulnerability scanning anywhere**. We push images, we deploy
   them; nothing in between tells us "this base image has 47 critical
   CVEs". Zot ships Trivy as a built-in extension that scans on push
   and updates the CVE DB daily.
3. **DockerHub rate limits and outages affect us**. Anonymous pulls are
   rate-limited globally; authenticated pulls have a higher but still
   finite limit. A new node joining DOKS during an incident must pull
   every image from DockerHub — a known-bad behaviour during DockerHub's
   periodic outages.

## Target architecture

```
                         GitHub Actions (CI)
                                │
                                │ docker push
                                ▼
                ┌──────────────────────────────────────────┐
                │  registry.platform.fmd.fagorhealthcare.com   │
                │  Caddy (Let's Encrypt) → zot:5000        │
                └──────────────┬───────────────────────────┘
                               │ on the platform droplet
                               ▼
                       ┌───────────────┐
                       │  Zot (compose)│   storage backend = S3
                       │  + Trivy ext. │   ─────────────────────►  DO Spaces
                       │               │                           "platform-registry"
                       └───────┬───────┘                           (fra1, same DC as cluster)
                               │
                               │ extension API
                               ▼
                  /v2/_zot/ext/search?cve  (consumed later by `fhctl images`)

                                                 ┌─────────────────────┐
        md-backup CronJob (extended)  ────────►  │ AWS S3 (existing)   │
        rclone sync from Spaces                  │ /registry/ prefix   │
                                                 │ Std → IA@30d → Gl   │
                                                 └─────────────────────┘
```

See [06-platform-tier.md](06-platform-tier.md) for the host-level layout
(Caddy + docker-compose + DR plan + Terraform).

### Why Zot, specifically

- **Distribution** (the upstream OCI ref impl): too bare. No scanning,
  no search API, no GUI. Would need a sidecar plus glue. Cheap, but
  we'd build what Zot already gives us.
- **Harbor**: feature-complete, but it ships ~6 components (core,
  jobservice, registry, db, redis, trivy, portal) and a Postgres
  dependency. Overkill for ~7 image repositories and a single-team
  operation. Operational tax is real.
- **Zot**: single Go binary, OCI-1.1 compliant, S3 backend native,
  Trivy built in, GUI included, open governance under CNCF Sandbox.
  Runs in a single `docker compose` service. The sweet spot for our
  scale.

### Storage: DO Spaces (`platform-registry`)

- S3-compatible API → Zot's `s3` storage driver works out of the box.
- `fra1` region → same datacentre as both DOKS clusters and the
  platform droplet → intra-DC pulls are free (no egress charges).
- Lifecycle rule: nothing automatic; manifests are append-only by
  `<branch>.<run>` tag, so even abandoned branches are tiny compared
  to DOKS storage in general.
- Estimated steady-state size: ~7 services × ~80 builds retained ×
  ~300 MiB per layer (deduped) = ~5 GiB. Fits comfortably in the
  smallest Spaces tier; the `platform-registry` and `platform-logs`
  buckets together stay inside one $5/mo base unit.

### Backup / DR: AWS S3 (existing `md-backup` bucket)

- Extend the `md-backup` CronJob with an `rclone sync` step to mirror
  `spaces:platform-registry/` to the existing AWS S3 bucket under the
  `/registry/` prefix.
- Lifecycle policy on that prefix: Standard → Standard-IA at 30 days →
  Glacier (Deep Archive) at 180 days.
- AWS S3 IA at ~5 GiB is ~$0.06/mo for storage + minimal request
  charges. Round to $1/mo for the registry portion.
- This is a true offsite, second-cloud DR copy. If DigitalOcean has a
  region-wide outage we can re-point Zot at the AWS bucket as
  read-only and keep deploys working from cached images.

### Vulnerability scanning

Zot's `extensions.search.cve` block enables Trivy CVE updates daily and
exposes findings via:

```
GET /v2/_zot/ext/search?query={CVEListForImage(...)}
```

Plumb this into a future `fhctl images cves <service>` command. Initial
target: just human-readable output. Later: a "block prod deploy if any
CRITICAL" gate in `release.yml`.

> **DEFERRED — Zot v2.1.5 + S3 backend incompatibility (2026-05-07)**
>
> On first bring-up Zot rejected its config with:
> `failed to enable cve scanning due to incompatibility with remote storage, please disable cve`.
> Zot's CVE scanner (Trivy DB) requires a local-fs storage backend; with
> a pure-S3 storage driver the validator hard-fails. Adding a local
> `cacheDriver` (boltdb) does not satisfy the check — the validator
> looks at `storageDriver`, not the cache.
>
> Workarounds, ordered by ease:
> 1. **Local storage + rclone sync to Spaces** — switches the chosen
>    architecture; CVE scanning works; backup is async. Best long-term.
> 2. **Pin Zot to a version that supports CVE+S3** — needs investigation
>    in the Zot issue tracker; there may not be one.
> 3. **Live without CVE scanning** — current state. Search extension is
>    still enabled (image listing, tag search), only the CVE sub-block
>    is disabled.
>
> Current state: option 3. The `extensions.search.cve` block is removed
> from `zot/config.json.tmpl`. Re-enabling it requires picking option 1
> or 2 and is tracked as an open follow-up — NOT a v1 blocker, since
> the registry itself works and replaces DockerHub for image hosting.

## Cost delta

| Change | Monthly delta |
|---|---|
| DockerHub Pro / paid plan canceled | **−$5 to −$10** |
| DO Spaces (`platform-registry`, ~5 GiB) | **+$0** (shares the $5 base unit with `platform-logs`; counted in pillar 06) |
| AWS S3 IA mirror (~5 GiB) | **+$0.50** |
| Zot service compute | **$0** (runs in the platform droplet's compose stack — see pillar 06) |
| **Net** | **~$0/mo** |

The platform droplet hosting cost is accounted in pillar 06, not here,
to avoid double-counting.

## Bootstrap image — pin the Zot image off-DockerHub

Zot publishes images to **GitHub Container Registry** (`ghcr.io`), not
DockerHub. Use the GHCR path explicitly so we never depend on DockerHub
for Zot itself:

```yaml
image: ghcr.io/project-zot/zot-linux-amd64:vX.Y.Z   # pin specifically
```

Verify the latest stable tag at `https://github.com/project-zot/zot/releases`
before applying. **Never** use `:latest` for Zot — a silent upgrade with
schema changes can brick the registry on restart.

This is the only bootstrap dependency: the platform droplet pulls Zot
from GHCR on first boot. Every other `gailen/*` image moves to Zot
once cutover completes.

## Work breakdown (~1 day)

The platform droplet (pillar 06) must be up before this pillar starts.
Once it is, the registry-specific work is light because there is no
Helm/cert-manager friction — just a docker-compose service.

### Step 1 — Stand up Zot on the platform droplet (~2 h)

- Add the `zot` service to `/opt/platform/docker-compose.yml` (skeleton
  in pillar 06).
- Author `zot-config.json` with the S3 driver pointing at
  `platform-registry`, extensions for `search`, `cve` (Trivy with
  daily refresh), `ui`, `metrics`.
- Generate `htpasswd` for the `ci` user; commit the bcrypt-hashed
  entry (the hash is not a secret, but the cleartext password is —
  store via Terraform variable / 1Password reference).
- Add the `registry.platform.fmd.fagorhealthcare.com` block to the
  `Caddyfile` (skeleton in pillar 06).
- `docker compose up -d zot caddy && docker compose logs -f zot` to
  watch the first start.
- Verify push/pull manually: `docker login
  registry.platform.fmd.fagorhealthcare.com -u ci`, push a smoke image,
  pull from a pod via a test pull-secret in dev cluster.

### Step 2 — Cut over a pilot service (~2 h)

- Pick `md-backup` (lowest blast radius — runs as a CronJob, not in
  the serving path).
- Update its `cd.yaml` to push to
  `registry.platform.fmd.fagorhealthcare.com/md-backup` in parallel to
  DockerHub for one cycle, then DockerHub-only off.
- Add the new registry to `md-dockerhub-regcred` (rename the secret
  to `platform-regcred` for clarity, but keep DockerHub creds
  alongside Zot creds — the pull-secret format is a list of
  registries).
- Verify the pilot deploys cleanly. Roll back is `kubectl set image`
  to the DockerHub digest.

### Step 3 — Roll the rest of the services (~2 h)

- One `cd.yaml` at a time: `md-pwa` → `md-resi-front` → `md-resi-back`
  → `md-auth` → `md-core` (most-critical last).
- After all dev `cd.yaml`s push to Zot, update `release.yml` (Release
  to PROD) to also push to Zot. Pre cluster pulls from
  `registry.platform.fmd.fagorhealthcare.com` over public TLS (same fra1
  datacentre, sub-ms latency, no egress charges).
- **Do not delete DockerHub repositories yet.** Keep them as a
  fallback read-only mirror for at least one full release cycle.

### Step 4 — Replace `add_tag.sh` (~2 h)

- Replace the manifest-PUT-via-curl approach with `oras tag` against
  Zot. Zot supports OCI distribution-spec tag operations natively, so
  the hardcoded credential goes away — CI uses a per-job service token
  (htpasswd `ci` user) issued via Zot's HTTP basic auth or, later, a
  GitHub OIDC flow if Zot's auth extensions are enabled.
- Extend `md-backup`'s CronJob spec to include the registry `rclone
  sync` step.
- Update `docs/INFRASTRUCTURE.md` and `docs/DEPLOYMENT.md` (in this
  repo) to reflect the new registry hostname and tag mechanics.

## Risks and gotchas

- **Chicken-and-egg on Zot itself**: see "Bootstrap image" above. Zot's
  own image stays on **GHCR**, not DockerHub or Zot. Documented in the
  platform repo's `bootstrap.sh`.
- **Pull-secret confusion**: kubelets currently use
  `md-dockerhub-regcred`. Adding the Zot endpoint requires updating
  *every* Deployment's `imagePullSecrets`. Easier: rename the secret
  to `platform-regcred`, embed both endpoints, and set it as
  `imagePullSecrets` on the default `ServiceAccount` so new manifests
  inherit it.
- **NetworkPolicy**: if/when we adopt NetworkPolicies, the pre cluster's
  egress to `registry.platform.fmd.fagorhealthcare.com` must be allowed
  explicitly. For now there are no NPs in place.
- **The hardcoded DockerHub credential lives on** until step 4 above.
  Do not push the new docs claiming "rotated" until `add_tag.sh` is
  gone.
- **TLS for the registry**: Caddy auto-issues from Let's Encrypt. Rate
  limits are 50 certs/week per registered domain. We are nowhere near
  this. Caddy stores ACME state on the droplet's `caddy_data` volume;
  losing the droplet means re-issuance on the new droplet (~30 s).
- **`cinfa-adhoc-cert` is not affected by this pillar.** No ingress
  entries for `*.cinfa.com` change. (Re-flagging because the registry
  endpoint is on a *different* hostname zone entirely now —
  `*.platform.fmd.fagorhealthcare.com`, not `*.k8s.gailen.net` and not
  the app cluster's NGINX. Accidental config bleed across clusters
  is no longer the failure mode to watch for; instead, watch for
  accidental Caddy config edits affecting both routes.)

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

- [ ] Platform droplet (pillar 06) is up and `registry.platform.fmd.fagorhealthcare.com` resolves to it
- [ ] All `gailen/*` images mirrored to Zot for at least one release cycle
- [ ] All `cd.yaml` and `release.yml` workflows push to Zot
- [ ] `add_tag.sh` rewritten to use `oras` against Zot, hardcoded
      DockerHub credential removed from the codebase
- [ ] `md-backup` extended with the `rclone sync` step (registry
      portion), verified once with the AWS S3 lifecycle policy
- [ ] DockerHub paid plan downgraded or canceled
- [ ] Trivy scan results visible for every active image
- [ ] `INFRASTRUCTURE.md` and `DEPLOYMENT.md` in this repo updated
