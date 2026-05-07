# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this directory is

This is **not a single repository**. It is the local workspace root for the **Fagor Healthcare Medical Dispenser (MD) platform** — a collection of independently versioned Git repositories (one per service) that together form a multi-service healthcare application. There is no top-level `git` repo here; each subdirectory has its own remote on GitHub under `https://github.com/FagorHealthcare/`.

When asked to work on "the project", clarify which repo. When asked to deploy or operate "the system", coordinate across repos.

## Repositories at this level

| Directory | Repo | Purpose |
|---|---|---|
| `md-core/` | FagorHealthcare/md-core | Java 17 / Quarkus backend — main Medical Dispenser service (WhatsApp, MQTT, scheduling, sync) |
| `md-pwa/` | FagorHealthcare/md-onboarding-pwa | Angular 12 + Ionic PWA — patient onboarding/tracking front-end |
| `md-auth/` | FagorHealthcare/md-auth | Java 17 / Quarkus — authentication & JWT issuance, Cinfa Salesforce integration |
| `md-resi-back/` | FagorHealthcare/md-resi-back | Java 17 / Quarkus — residence (residencia) backend, AEMPS pharma data |
| `md-resi-front/` | FagorHealthcare/md-resi-front | Angular 15 + Material — residence staff web app |
| `md-backup/` | FagorHealthcare/md-backup | Alpine container — Postgres + K8s descriptor backup to S3 (CronJob) |
| `k8s/` | FagorHealthcare/k8s | Kustomize manifests for all environments — single source of truth for deployment |
| `do-functions/` | FagorHealthcare/do-functions | Node.js 18 — DigitalOcean Functions for medicine catalog sync, log cleanup |
| `sync-api-spec/` | FagorHealthcare/sync-api-spec | OpenAPI spec — pharmacy↔backend sync API (consumed by md-core) |
| `md-resi-api-spec/` | FagorHealthcare/md-resi-api-spec | OpenAPI spec — residence API (consumed by md-resi-back & md-resi-front) |
| `fmd-manual/` | FagorHealthcare/fmd-manual | MkDocs — published end-user manual (GitHub Pages) |
| `pruebas-fmd-manual/` | jorgeuriarte/pruebas-fmd-manual | Personal testing fork of the manual |
| `postman-cinfa/` | FagorHealthcare/postman-cinfa | Postman collections — Cinfa Salesforce integration tests |

## Documentation index

Comprehensive system documentation lives under `docs/`. Start here:

- [docs/DOCS.md](docs/DOCS.md) — index of all system documentation
- [docs/SYSTEM.md](docs/SYSTEM.md) — architecture overview, service map, data flows
- [docs/SERVICES.md](docs/SERVICES.md) — per-service reference (build, run, API surface)
- [docs/INFRASTRUCTURE.md](docs/INFRASTRUCTURE.md) — clusters, DNS, registries, observability
- [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) — image tag strategy, deploy/rollback runbooks
- [docs/OPERATIONS.md](docs/OPERATIONS.md) — daily ops, certs, secrets, troubleshooting
- [docs/INCIDENTS.md](docs/INCIDENTS.md) — incident playbook and history
- [docs/fhctl-DESIGN.md](docs/fhctl-DESIGN.md) — design sketch for `fhctl`, the operator/agent CLI
- [k8s/CLAUDE.md](k8s/CLAUDE.md) — focused guidance for the Kubernetes manifests repo (cert-manager, cinfa cert renewal, JWT keys)

## Architecture in one paragraph

Three Quarkus backends (`md-core`, `md-auth`, `md-resi-back`) and two Angular front-ends (`md-pwa`, `md-resi-front`) deploy as independent Kubernetes Deployments behind a single NGINX Ingress per environment. They share one DigitalOcean managed PostgreSQL cluster (separate Flyway migration histories). `md-core` integrates with Twilio (WhatsApp), MQTT (physical SHC dispensers), and Quartz (scheduled medication reminders). `md-auth` integrates with Cinfa Salesforce for pharmacy activation. `md-resi-back` integrates with AEMPS (Spanish pharmaceutical regulator). NodeRed and n8n run as StatefulSets with PVCs for workflow automation. `md-backup` runs as a CronJob, `do-functions` runs serverless. Image registry is DockerHub `gailen/*`. All clusters are DigitalOcean Managed Kubernetes (DOKS) in Frankfurt.

## Critical operational facts (read before deploying)

1. **There are TWO production-relevant clusters, both DOKS-Frankfurt**:
   - `md-dev-cluster` — serves the `dev-0` environment (`*.k8s.gailen.net`)
   - `md-pre-cluster` — **serves real production traffic** (`app.fagorhealthcare.com`, `fmd.fagorhealthcare.com`, `medicaldispenser-sw.cinfa.com`)
   - The `k8s/environments/prod/` overlay exists but is **incomplete and unused** — do not deploy with it.
   - The GitHub Actions workflow named `release.yml` ("Release to PROD") **deploys to `md-pre-cluster`**. Naming is misleading; "pre" is production.

2. **Always verify `kubectl config current-context` before any cluster action.** Wrong-cluster deploys are the #1 risk. Match `do-fra1-md-dev-cluster` for dev, `do-fra1-md-pre-cluster` for prod.

3. **Image tags follow the pattern `<branch>.<run_number>`** (e.g. `main.247`). Floating tags `dev`, `prod`, and `latest` are re-pointed by `add_tag.sh` after each successful deployment via the DockerHub manifest API.

4. **`add_tag.sh` contains a hard-coded DockerHub credential** (`gailen:873e27e5-…`). Treat it as a secret. Do not echo it in logs. Future work: rotate and move to GH secrets.

5. **DB migrations run automatically on pod startup** (Flyway, `migrate-at-start=true`). Pre-prod and prod use `migrate` (not `clean`). A bad migration brings the service down on rollout — review SQL carefully and test on dev first.

6. **The `cinfa-adhoc-cert` TLS secret is a manual DigiCert wildcard**, NOT cert-manager-managed. See `k8s/CLAUDE.md` for the renewal runbook. Adding `cert-manager.io/issuer` annotation to its ingress entry would silently overwrite it with Let's Encrypt and break `medicaldispenser-sw.cinfa.com`.

7. **Per-service deployment is not coordinated.** Each repo's `cd.yaml` deploys to dev independently on push to `main`. There is no orchestrator that ensures `md-core` and `md-pwa` ship a compatible pair. Mind API contract changes.

## Common commands per service

Each service is built and run differently. Quick reference:

### Quarkus services (md-core, md-auth, md-resi-back)

```bash
# Build (JIB pushes image when configured)
./mvnw package
./mvnw package -Dquarkus.container-image.build=true -Dquarkus.container-image.push=true

# Dev mode (hot reload)
./mvnw quarkus:dev

# Single test
./mvnw test -Dtest=ClassName#methodName
```

### Angular services (md-pwa, md-resi-front)

```bash
# Install
npm install

# Generate API client from OpenAPI spec (must run before build if spec changed)
npm run build-api               # md-pwa
npm run generate-auth-api && npm run generate-web-api   # md-resi-front

# Dev server
npm start

# Production build
npm run build
```

### Kubernetes (k8s/)

```bash
# ALWAYS verify context first
kubectl config current-context

# Apply env (safe — only changes what kustomize emits)
kubectl apply -k environments/dev-0/
kubectl apply -k environments/pre/

# Roll a single image (faster than re-applying)
kubectl set image deployment/md-core md-core=gailen/md-core:main.247
kubectl rollout status deployment/md-core --timeout=120s

# Rollback
kubectl rollout undo deployment/md-core
```

### Deploy to dev (automatic)

`git push` to `main` on any backend repo triggers `.github/workflows/cd.yaml`:
1. Maven build + Docker push of `gailen/<svc>:main.<run>`
2. `kubectl set image` against `md-dev-cluster`
3. `add_tag.sh` re-tags the image as `dev`
4. POST to `https://nrapi.fmd.fagorhealthcare.com/v0/versionOnline` (version tracker)
5. Slack notification to `#circupack`

### Promote dev → production

Manual GitHub Actions dispatch (`Actions → Release to PROD → Run workflow`):
- Inputs: `image_name` (branch, e.g. `main`), `image_version` (run number, e.g. `247`)
- Effect: `kubectl set image` against `md-pre-cluster`, re-tag as `prod` in DockerHub.
- No automatic smoke test runs after — verify manually via `/q/health` endpoints.

## Local working environment

- The project lives on the external drive `/Volumes/SHEVEK_EXTERNO/`. If commands return "No such file or directory" with paths under `/Volumes/SHEVEK_EXTERNO/...`, the drive has unmounted — ask the user to remount before continuing.
- The user's tooling routes some `ls` calls through `rtk` which can return empty output. Use `/bin/ls` directly when in doubt.
- Each subdirectory is an independent git repo. `cd` into the specific repo before running `git` commands; do not assume a top-level git context.

## Conventions specific to this project

- **Spanish + English mixed**: code comments, commit messages, and Slack messages are often Spanish. Documentation aimed at end users (`fmd-manual`) is multi-lingual.
- **i18n source of truth is a public Google Sheet** (`13vJc259xTDELpiwxi85j84D9Dhr63Fo2GRiI5WS10ZM`); the `i18n/` tooling pulls translations down to per-locale JSON files.
- **`auth-library`** is a multi-module Maven artifact published from the `md-auth` repo to GitHub Packages. `md-core` and `md-resi-back` consume it for shared JWT/PharmacyAuthenticationContext code. Keep it backwards-compatible.
- **`sync-api-spec` and `md-resi-api-spec` are git submodules** in some repos. After cloning, `git submodule update --init`. They are also pulled directly via `git clone` in CI (see `md-pwa/Jenkinsfile`).
- The `k8s/data/` directory contains a captured `nodered-flows-infected.json` from a March 2026 cryptominer incident — preserved as forensic evidence; do not delete. See `docs/INCIDENTS.md`.
