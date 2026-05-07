# DEPLOYMENT — How code reaches production

## Image lifecycle (the canonical flow)

```
git push  ─►  GitHub Actions cd.yaml  ─►  build + test
                                              │
                                              ▼
                                    DockerHub: gailen/<svc>:<branch>.<run>
                                    DockerHub: gailen/<svc>:<branch>.latest
                                    DockerHub: gailen/<svc>:latest
                                              │
                       (only if branch == main)
                                              ▼
                                    kubectl set image  →  md-dev-cluster
                                              │
                                              ▼
                                    add_tag.sh: re-tag <branch>.<run> as 'dev'
                                              │
                                              ▼
                                    POST nrapi/v0/versionOnline
                                              │
                                              ▼
                                    Slack #circupack notification

──── (later, manual approval) ─────────────────────────────────────────

Operator: GitHub Actions → "Release to PROD" → workflow_dispatch
Inputs: image_name=main, image_version=247
                                              │
                                              ▼
                                    kubectl set image  →  md-pre-cluster
                                              │
                                              ▼
                                    add_tag.sh: re-tag main.247 as 'prod'
                                              │
                                              ▼
                                    POST nrapi/v0/versionOnline (env=prod)
                                              │
                                              ▼
                                    Slack #circupack notification
```

There is **no automatic promotion** from dev to prod. Production deploys are always operator-initiated via GitHub Actions UI.

## Per-service deploy mechanism

| Service | CI workflow | Auto-deploys to dev on push to `main`? | Production workflow |
|---|---|---|---|
| md-core | `.github/workflows/cd.yaml` | yes | `release.yml` (manual) |
| md-auth | `.github/workflows/cd.yaml` | yes | `release.yml` (manual) |
| md-resi-back | `.github/workflows/cd.yaml` | yes (uses `doctl` for kubeconfig) | `release.yml` (manual) |
| md-pwa | `.github/workflows/cd.yaml` | yes | `release.yml` (manual) |
| md-resi-front | `.github/workflows/ci.yaml` | yes (every branch deploys to dev — note this differs) | manual |
| md-backup | none | no — image must be built and pushed manually | n/a |
| do-functions | none | no — `doctl serverless deploy` from operator's laptop | n/a |
| k8s | none | no — `kubectl apply -k` from operator's laptop | applied to both dev and pre |

Note `md-resi-front`'s `ci.yaml` deploys **every branch** to dev (no `main`-only gate). This is different from the backend pattern.

## Image tag strategy

Two layers:

### 1. Immutable build tag (always pushed)

`<branch>.<run_number>`, e.g. `main.247`. CI also adds `<branch>.latest` and plain `latest`. These come from the build job and never change once published.

### 2. Floating environment tag (re-pointed)

After a successful kubectl rollout, `.github/workflows/add_tag.sh <build_tag> <env_tag> <project>` makes a DockerHub manifest API call that aliases the floating tag to the same digest:

```bash
# pseudo-code from add_tag.sh
TOKEN=$(curl -u gailen:<hardcoded> auth.docker.io/token?...)
MANIFEST=$(curl -H "Auth: Bearer $TOKEN" registry.hub.docker.com/v2/gailen/<svc>/manifests/main.247)
curl -X PUT -H "..." -d "$MANIFEST" registry.hub.docker.com/v2/gailen/<svc>/manifests/dev
```

Floating tags currently in use:
- `dev` — what's running in `md-dev-cluster`
- `prod` — what's running in `md-pre-cluster`
- `latest` / `<branch>.latest` — moved by build, not by deploy

**Reading these tags is how you find "what's running":**

```bash
# What digest does prod alias right now?
docker buildx imagetools inspect gailen/md-core:prod
# vs
docker buildx imagetools inspect gailen/md-core:main.247
# Same SHA256 = main.247 is what's running in prod
```

## Database migrations

- All Quarkus services run **Flyway on startup** (`migrate-at-start=true`). For `pre`, the property `quarkus.flyway.repair-at-start=true` is also set, which lets Flyway recover from interrupted prior migrations.
- Migrations live in each service's `src/main/resources/db/migration/V*.sql`.
- A migration that fails causes the pod to crash-loop. The service won't be Ready, the rolling update halts (because the new ReplicaSet has zero Ready pods), and the old pods keep serving traffic. **Net effect**: a bad migration doesn't break production immediately, but it does break the new deploy.
- There is no separate "migration job"; migrations are coupled to pod startup. This means **two pods migrate concurrently** during rolling update — Flyway's table-level lock is what prevents corruption. Test migrations with this in mind.

## Deploying a specific version manually

When CI is unavailable or when you need to deploy a non-`main` branch:

```bash
# 1. Verify context (NEVER skip this)
kubectl config current-context
# Expect: do-fra1-md-dev-cluster (or md-pre-cluster for prod)

# 2. Confirm the image exists in DockerHub
docker buildx imagetools inspect gailen/md-core:my-branch.42

# 3. Set image
kubectl set image deployment/md-core md-core=gailen/md-core:my-branch.42

# 4. Watch rollout
kubectl rollout status deployment/md-core --timeout=180s

# 5. Sanity-check
kubectl logs -l app=md-core --tail=50
curl -s https://app.fagorhealthcare.com/health/md-core | jq
```

## Rollback

### Fast rollback (preferred)

```bash
kubectl config current-context  # verify
kubectl rollout undo deployment/md-core
kubectl rollout status deployment/md-core --timeout=120s
```

This reverts to the previous ReplicaSet — works as long as the previous ReplicaSet still exists (default `revisionHistoryLimit` is 10).

### Specific-version rollback

If `rollout undo` is not enough (e.g. you want to skip back two versions):

```bash
# List rollout history
kubectl rollout history deployment/md-core

# Roll back to a specific revision number
kubectl rollout undo deployment/md-core --to-revision=42

# OR re-pin to a known-good image tag
kubectl set image deployment/md-core md-core=gailen/md-core:main.246
```

### What rollback does NOT undo

- **Database migrations** — Flyway never auto-reverses. If the new version added a column with `NOT NULL` and the old version doesn't write it, the old version may fail on insert. Test migrations for backward compatibility before deploying.
- **MQTT messages already sent** to SHC devices.
- **Quartz schedule changes** — if the new code wrote a new Quartz schedule into the DB, rolling back the code does not delete those rows.
- **Sent WhatsApp messages.**

### Rollback the floating tag too

After rolling back, also fix the `prod` (or `dev`) floating tag, otherwise the next operator who reads "what's in prod?" via `gailen/md-core:prod` will see the wrong digest:

```bash
# From inside any md-core checkout
sh .github/workflows/add_tag.sh main.246 prod md-core
```

## Pre-deploy checks (recommended before promoting to pre)

1. `kubectl get pods -n default` in dev — all `md-*` Ready, no recent restarts
2. Hit dev's health endpoints:
   ```bash
   for svc in md-core md-auth md-resi-back; do
     curl -s https://md.k8s.gailen.net/health/$svc | jq -e '.status == "UP"'
   done
   ```
3. Smoke-test critical paths:
   - md-pwa: load `https://app.k8s.gailen.net/` — service worker registers, root route renders
   - md-resi-front: log in with a test residence account
4. Inspect recent commit log on the source branch — anything unexpected?
5. Check Logtail for any new ERROR-level logs in the last hour

## Post-deploy checks (after promoting to pre)

1. `kubectl rollout status` returned success (CI does this, but verify)
2. `https://app.fagorhealthcare.com/health/<svc>` returns `{"status":"UP"}` for all
3. No new errors in Logtail since deploy timestamp
4. Twilio dashboard: WhatsApp deliveries continuing (md-core only)
5. Slack `#circupack` shows the deployment notification
6. The `nrapi/v0/versionOnline` POST succeeded (visible in CI logs)

## "What's running where?" — quickly answering this

```bash
# Per service, in current context
kubectl get deployment md-core -o jsonpath='{.spec.template.spec.containers[0].image}'
# → gailen/md-core:main.247

# What digest does that resolve to?
kubectl get deployment md-core -o jsonpath='{.spec.template.spec.containers[0].image}' \
  | xargs docker buildx imagetools inspect | grep -i digest

# Which build was that? (CI annotates the Quarkus app version)
curl -s https://app.fagorhealthcare.com/q/info | jq .application.version

# Frontend version (md-resi-front injects this)
curl -s https://fmd.fagorhealthcare.com/health/md-resi-front | jq
```

## Environment promotion contract

The convention in this org:

- A build promoted from dev to pre must be **the exact same image** — no rebuild. Tag-only operations.
- The version tracking API (`nrapi/v0/versionOnline`) records this fact and is the audit trail.
- If you find yourself re-building "the same code" for prod, stop — that breaks the contract and the auditability.

## Running `k8s/` apply

Most deploys are `kubectl set image` only. Full `kubectl apply -k environments/<env>/` is needed when:

- ConfigMap content changed (e.g. you edited `application.properties` for an env)
- Ingress rules changed
- A new service was added
- Secrets were rotated (and the secret resource was updated declaratively)

```bash
kubectl config current-context              # verify, twice
kubectl apply -k k8s/environments/dev-0/    # diff-then-apply
kubectl apply -k k8s/environments/pre/      # extra care
```

`kustomize build` first if you want to dry-run:

```bash
kustomize build k8s/environments/pre/ | less
```
