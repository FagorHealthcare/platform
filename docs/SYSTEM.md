# SYSTEM — Architecture Overview

## Product

**Fagor Healthcare Medical Dispenser (MD)** is a connected medication adherence platform. A patient (typically elderly) receives prepared blister packs from a local pharmacy and uses an SHC ("Smart Health Card") device — a physical dispenser that signals when each dose is due. The system tracks taken/missed doses, sends reminders, notifies caregivers, and supports two operational contexts:

- **Home / patient-direct** — patient + caregivers + pharmacy ("circupack" / "onboarding" flow), driven through the **md-pwa** patient app and **md-core** backend.
- **Residencia / residential care** — nursing home staff manage many patients at once, driven through the **md-resi-front** staff app and **md-resi-back** + **md-auth** backends.

Both contexts share the same SHC physical device firmware (programmed via MQTT from `md-core`) and the same identity layer (JWT issued by `md-auth`).

## Service map

```
                   Public DNS (Let's Encrypt + DigiCert)
                                 │
                       ┌─────────┴─────────┐
                       │  NGINX Ingress    │   (DOKS managed LB)
                       └─────────┬─────────┘
                                 │
        ┌──────┬───────┬─────────┼─────────┬───────┬──────────┐
        ▼      ▼       ▼         ▼         ▼       ▼          ▼
     md-pwa  md-resi  md-core  md-auth  md-resi  md-     md-n8n
     (PWA)   -front   (back)   (auth)   -back    node-   (workflow)
                                                 red
                       │       │         │
                       └───┬───┴────┬────┘
                           ▼        ▼
                     Postgres (DO managed)
                           │
                  Quartz, Flyway, JPA
                           │
                   ┌───────┴────────┐
                   ▼                ▼
              Twilio (WhatsApp)  MQTT broker (67.207.73.146:1883)
                                      │
                                      ▼
                                 SHC devices (physical)

External integrations:
  - Cinfa Salesforce  → md-auth (pharmacy activation)
  - AEMPS CIMA REST   → md-resi-back (Spanish drug catalog)
  - Sentry            → md-resi-front (error tracking)
  - Logtail           → vector → all pods (log aggregation)
```

### Service responsibilities

| Service | Layer | Owns |
|---|---|---|
| **md-core** | Backend | Patient tracking, treatment scheduling, WhatsApp notifications, SHC device programming via MQTT, sync API for pharmacy systems, Quartz job scheduling, activity logs |
| **md-auth** | Backend | User & pharmacy authentication, JWT issuance/refresh, FMD device activation, Cinfa Salesforce OAuth dance, password reset, document acceptance/signing |
| **md-resi-back** | Backend | Residence patient registry, medication catalog (AEMPS lookup), prescription handling, Excel export of patient state |
| **md-pwa** | Frontend | Mobile-first PWA for patients/caregivers — onboarding, treatment view, blister tracking, install prompts |
| **md-resi-front** | Frontend | Desktop/tablet web app for residence staff — patient lists, medication management, PDF document viewing |
| **md-node-red** | Infrastructure | Visual flow automation; bridge between MQTT events and HTTP webhooks |
| **md-n8n** | Infrastructure | Workflow orchestration for ad-hoc integrations |
| **md-backup** | Operations | Nightly Postgres dump + K8s manifest snapshot to S3 (CronJob) |
| **vector** | Observability | DaemonSet collecting all pod logs → Logtail.com |
| **do-functions** | Serverless | Out-of-cluster jobs: medicine catalog ingestion, Elasticsearch index cleanup |

## High-level data flows

### A. Pharmacy loads a treatment

1. Pharmacy software calls `POST /sync/auth` on `md-core` with NIF + activation code → 401-or-JWT
2. Pharmacy calls `POST /sync/carga` with `{patient, treatment, blisters[]}` payload
3. `md-core` persists to Postgres (Tratamiento, Blister, Toma tables)
4. `md-core` emits MQTT message on `shc-config` topic to program the patient's SHC device
5. `md-core` schedules Quartz reminder jobs (per-toma, hourly check)

### B. Patient takes a dose (or doesn't)

1. SHC device emits "alveolo opened" event on MQTT `command/<deviceId>`
2. `md-core` ingests via `@Incoming("shc-config-request")` handler
3. Toma row updated with timestamp; ActivityLogEntry written
4. If missed past tolerance, Twilio WhatsApp message sent to caregiver
5. ShcController POSTs back acknowledgment to device queue

### C. Residence staff adds a patient

1. Staff logs into `md-resi-front` → `POST /auth` against `md-auth` → JWT
2. Staff creates patient via `md-resi-front` → `POST /resi/...` against `md-resi-back`
3. `md-resi-back` validates medications via AEMPS REST (`https://cima.aemps.es/cima/rest`)
4. Treatment becomes visible to `md-core` once assigned to a registered SHC device

### D. Pharmacy onboarding via Cinfa

1. Pharmacy accepts in Cinfa Salesforce → triggers webhook
2. `md-auth` `POST /cinfa/activate/{cinfaCode}` creates pharmacy user
3. md-auth obtains OAuth token from `cinfa.lightning.force.com/services` using client_credentials
4. md-auth calls back into Cinfa Community to mark activation complete
5. JWT issued to the pharmacy with `ROLE_PHARMACY` claim

### E. Patient onboarding (PWA)

1. Patient opens shareable link → `md-pwa` loads, reads `config.js` for API URL
2. PWA hits `POST /seguimiento` on `md-core` to set up tracking
3. Patient receives SMS with Twilio link → confirms phone
4. PWA registers Service Worker; subsequent loads work offline

## Multi-tenancy

- **Tenancy unit**: pharmacy (a `Pharmacy` entity persisted in `md-auth`).
- **Enforcement**: every JWT carries a `pharmacy_id` claim. Backend services derive `PharmacyAuthenticationContext` from the JWT and use it as a row-level filter in Panache repositories.
- **There is no schema-per-tenant**; all tenants share tables, isolated by `pharmacy_id` column.

## Authentication chain

```
User/pharmacy credentials
        │
        ▼
   POST /auth (md-auth)
        │
        ▼
   JWT (RS256, mp.jwt issuer = https://{env}.fagorhealthcare.com)
        │
        ├──► presented to md-core      │  Verified locally with public key
        ├──► presented to md-resi-back │  mounted from k8s secret
        └──► presented to md-resi-front│  ssh-key-secret/ssh-publickey
```

Refresh: `POST /fmd/refresh` requires `ROLE_*_REFRESH`. JWT lifetime is 1 day; refresh tokens last 5–7 days depending on env.

JWT keys are RSA 2048, generated locally per environment (see `k8s/SECURITY.txt`), stored as the `ssh-key-secret` Kubernetes Secret, mounted at `/etc/secret-volume/ssh-publickey` and `/etc/secret-volume/ssh-privatekey`.

## Environments

Three logical environments. Critical: only the first two are real.

| Env | k8s overlay | Cluster | DNS | Image tag floating ref | Purpose |
|---|---|---|---|---|---|
| **dev-0** | `k8s/environments/dev-0/` | `do-fra1-md-dev-cluster` | `*.k8s.gailen.net` | `dev` | Active development; auto-deployed from `main` |
| **pre** | `k8s/environments/pre/` | `do-fra1-md-pre-cluster` | `app.fagorhealthcare.com`, `fmd.fagorhealthcare.com`, `medicaldispenser-sw.cinfa.com` | `prod` | **Live production** — name is misleading |
| **prod** | `k8s/environments/prod/` | (none — overlay incomplete) | n/a | n/a | Stub; do not deploy |

The `pre` cluster is the production-serving environment. The "Release to PROD" GitHub Actions workflow targets `md-pre-cluster`. This naming is historical and is the **single most error-prone fact** about this system.

## What is NOT in this repo

- **SHC device firmware** — separate codebase, MQTT broker is the only contact surface.
- **Pharmacy POS integration code** — pharmacies use third-party software (Cinfa, etc.) that calls the public sync API.
- **Hardware schematics**, telecom contracts, regulatory filings.
