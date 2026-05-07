# fhctl — Design Sketch

A unified operator/agent CLI for the Fagor Healthcare platform. Wraps the seven or eight tools an operator currently chains by hand — `kubectl`, the DockerHub manifest API, GitHub CLI, `curl` against health endpoints, `psql`, `doctl`, and the version-tracker API — behind a single, scriptable, agent-friendly surface.

## Goals

1. **One safe path** for the routine operations: status, logs, deploy, rollback, certs.
2. **Equally usable by humans and LLM agents.** Every command supports `--json` for structured output; every action has a `--dry-run`. No interactive prompts unless explicitly requested.
3. **Hard-coded safety rails** for things you can't easily un-do: cluster-context verification, env-name confirmation, prod-deploy gating.
4. **No new infra to deploy.** Pure client-side binary; reads the same kubeconfig and tokens you already use.

## Non-goals

- Replacing `kubectl` for ad-hoc cluster admin (use `kubectl` directly for things outside the supported surface)
- Replacing GitHub Actions as the canonical CI/CD path (`fhctl release` triggers the existing workflow; doesn't reimplement the build)
- Cluster provisioning, IAM, billing — out of scope

## Implementation choice

**Recommended: Go**, distributed as a single static binary. Reasons:
- Same SDK surface as `kubectl` (`client-go`) — cheap to call k8s APIs natively
- Cross-compile for macOS (operator laptops) and Linux (CI runners, agent containers)
- Natural fit for `--json` output via `encoding/json`
- Cobra for subcommand layout (battle-tested in `kubectl`, `gh`, `doctl`)

Alternative: Rust (if performance and binary size matter more than SDK ecosystem). Rejected for now because the k8s Go SDK is well-trodden and Cobra ergonomics are hard to match.

Distribution: GitHub Releases on `FagorHealthcare/fhctl`, brew tap, plus a published Docker image `gailen/fhctl:latest` so it can run inside CI containers without install.

## Configuration

```yaml
# ~/.fhctl/config.yaml
default_env: dev-0   # one of: dev-0, pre

environments:
  dev-0:
    cluster_context: do-fra1-md-dev-cluster
    namespace: default
    base_url: https://md.k8s.gailen.net
    pwa_url: https://app.k8s.gailen.net
    fmd_url: https://fmd.k8s.gailen.net
    image_tag_floating: dev
  pre:
    cluster_context: do-fra1-md-pre-cluster
    namespace: default
    base_url: https://app.fagorhealthcare.com
    fmd_url: https://fmd.fagorhealthcare.com
    cinfa_url: https://medicaldispenser-sw.cinfa.com
    image_tag_floating: prod

services:
  - name: md-core
    image: gailen/md-core
    repo: FagorHealthcare/md-core
    health_path: /q/health
    type: quarkus
  - name: md-auth
    image: gailen/md-auth
    repo: FagorHealthcare/md-auth
    health_path: /q/health/ready
    type: quarkus
  - name: md-resi-back
    image: gailen/md-resi-back
    repo: FagorHealthcare/md-resi-back
    health_path: /q/health
    type: quarkus
  - name: md-pwa
    image: gailen/md-pwa
    repo: FagorHealthcare/md-onboarding-pwa
    health_path: /
    type: angular-spa
  - name: md-resi-front
    image: gailen/md-resi-front
    repo: FagorHealthcare/md-resi-front
    health_path: /
    type: angular-spa

registry:
  type: dockerhub
  namespace: gailen
  credentials_env: DOCKERHUB_USER,DOCKERHUB_PASS

version_tracker:
  url: https://nrapi.fmd.fagorhealthcare.com/v0/versionOnline
  enabled: true

slack:
  webhook_env: FAGOR_SLACK_WEBHOOK_URL
  channel: circupack
```

Credentials live in the OS keychain (macOS Keychain via `keyring` Go lib, or `pass` on Linux); not in this file. Standard env-var fallback for CI.

## Global flags

| Flag | Purpose |
|---|---|
| `--env <env>` | Target environment. Required for any command that touches a cluster. |
| `--json` | Emit machine-readable JSON. Implies no decoration, no progress spinners, no colour. |
| `--dry-run` | Print the actions that would be taken; do not execute. |
| `--yes` | Skip interactive confirmations. Required in non-TTY contexts (CI / agents). |
| `--verbose` / `-v` | Log every underlying API call. |

## Safety contract

Every command that mutates state runs these gates first, in order:

1. **Context check** — `kubectl current-context` matches the target env's `cluster_context`. Mismatch → abort with explicit fix instructions.
2. **Cluster name check** — `kubectl get-clusters` confirms the kubeconfig actually points to the expected DOKS cluster (not a stale alias). Cross-check against `doctl kubernetes cluster get` if `doctl` is available.
3. **Env confirmation** — for `--env pre`, require `--yes` (or interactive `y/N`) and echo the action with the env in red. No silent prod operations.
4. **Out-of-band telemetry** — record a structured event to a local `~/.fhctl/audit.log` and (if enabled) Slack, *before* executing.

If any gate fails, exit code is nonzero and stderr explains exactly which gate, with the remediation command.

## Command surface

### Discovery & status

```
fhctl describe                    # what this CLI knows about (envs + services)
fhctl describe --env pre

fhctl status                      # multi-service health snapshot, current env
fhctl status --env pre --json     # same, json
fhctl status md-core --env pre    # one-service detail (image tag, replicas, last rollout)

fhctl images md-core              # list build tags from DockerHub, newest 20
fhctl images md-core --tag prod   # resolve a floating tag → digest → which build it points to
```

Example human output:

```
$ fhctl status --env pre
ENV: pre   CONTEXT: do-fra1-md-pre-cluster   ✓ verified

SERVICE        IMAGE TAG       READY   AGE     HEALTH
md-core        main.247        2/2     3d      UP
md-auth        main.119        2/2     12d     UP
md-resi-back   main.84         2/2     5d      UP
md-pwa         main.412        2/2     1d      UP
md-resi-front  develop.55      2/2     2h      UP   ⚠ non-main branch in pre
md-node-red    -               1/1     45d     UP
md-n8n         -               1/1     45d     UP
```

JSON output (the same data, `--json`):

```json
{
  "env": "pre",
  "context": "do-fra1-md-pre-cluster",
  "context_verified": true,
  "services": [
    {
      "name": "md-core",
      "image": "gailen/md-core:main.247",
      "image_digest": "sha256:abc...",
      "ready": "2/2",
      "ready_replicas": 2,
      "desired_replicas": 2,
      "rollout_age_seconds": 259200,
      "health": {"status": "UP", "checks_failed": []},
      "warnings": []
    },
    {
      "name": "md-resi-front",
      "image": "gailen/md-resi-front:develop.55",
      "warnings": ["non-main branch deployed to pre"]
    }
  ]
}
```

### Logs

```
fhctl logs md-core --env pre                       # tail, follow
fhctl logs md-core --env pre --since=10m
fhctl logs md-core --env pre --grep ERROR          # client-side filter
fhctl logs md-core --env pre --json                # one JSON object per log line
fhctl logs md-core --env pre --previous            # crashed container
fhctl logs --env pre --all-services --since=5m     # multiplex, prefixed
```

`--json` mode emits one line per record — agents can pipe through `jq` or read incrementally.

### Deploy

```
# Deploy a specific build tag (immutable)
fhctl deploy md-core main.247 --env dev-0

# Resolve a floating tag and pin it explicitly (recommended)
fhctl deploy md-core --tag-from=dev --env dev-0
# → resolves dev → main.247 → pins kubectl set image to main.247

# Promote dev to pre (production)
fhctl deploy md-core --promote --env pre
# → reads what's running in dev-0 (main.247),
#   verifies pre context,
#   demands --yes,
#   does kubectl set image in pre,
#   re-tags main.247 as 'prod' in DockerHub,
#   POSTs to version tracker,
#   notifies Slack.

# Re-apply full kustomize overlay (when ConfigMaps/Ingresses change)
fhctl apply --env pre --dry-run
fhctl apply --env pre --yes
```

What `deploy` does under the hood (idempotent, verifiable each step):

1. Verify context (gate)
2. Verify image exists in DockerHub (HEAD on registry manifest)
3. `kubectl set image deployment/<svc> <svc>=gailen/<svc>:<tag>`
4. `kubectl rollout status` with timeout (default 180s, configurable)
5. Hit health endpoint until UP or timeout (default 60s)
6. Re-tag in DockerHub (`add_tag.sh` equivalent, native HTTP)
7. POST to version tracker
8. Slack notification
9. Print summary; exit 0 only if all of the above succeeded

If step 4 or 5 fails, fhctl **automatically rolls back** unless `--no-auto-rollback` is set.

### Rollback

```
fhctl rollback md-core --env pre              # to previous ReplicaSet
fhctl rollback md-core --env pre --to=246     # to specific revision
fhctl rollback md-core --env pre --to-tag=main.246   # to specific image tag
```

After rollback, also re-tag floating tag (e.g. `prod` → main.246) so the registry truth matches reality. This is the step humans often forget; fhctl always does it.

### Health

```
fhctl health --env pre                         # all services, all health endpoints
fhctl health md-core --env pre --watch         # poll every 2s
fhctl health --env pre --json                  # for agents
```

Exit code reflects health: 0 = all UP, nonzero = at least one service DOWN. Useful in CI gates.

### Images & tags

```
fhctl images md-core                            # list latest N build tags from DockerHub
fhctl images md-core --tag prod --resolve       # what build does 'prod' point to right now?
fhctl tag md-core main.247 --as=prod --env pre  # re-tag (with safety gates)
fhctl tag md-core --diff dev,prod               # compare floating tags across envs
```

The tag command replaces `add_tag.sh` end-to-end. Same DockerHub manifest API, but with credentials from keychain (not hardcoded), and an audit-log entry.

### Releases (GitHub Actions)

```
fhctl release md-core --branch=main --build=247 --to=prod
# Triggers the existing FagorHealthcare/md-core release.yml workflow_dispatch with
# image_name=main, image_version=247.
# fhctl waits for completion and surfaces the run status.

fhctl release-list md-core --limit=10            # last 10 release.yml runs

fhctl release-status md-core <run-id>            # detail
```

This is how an operator (or agent) does production deploys via the CLI without leaving the canonical CI path.

### Certificates

```
fhctl certs --env pre                          # all certs, expiry, issuer
fhctl certs --env pre --json
fhctl cert renew-cinfa --pfx=./wildcard.cinfa.com.2027.pfx --env pre --yes
# Walks the entire k8s/CLAUDE.md runbook end-to-end (backup, delete, recreate, restart ingress, verify).
```

### Database

```
fhctl db connect --env dev-0                   # shells you into psql with the right URL
fhctl db migrations md-core --env pre          # query flyway_schema_history
fhctl db backups list                          # last 30 nightly backups in S3
fhctl db backups verify --latest               # smoke test latest backup is restorable
```

`db connect` does not store credentials — it reads them from the env's ConfigMap (`kubectl get cm md-core-config -o jsonpath=...`) and shells out to `psql`. So the secret never touches disk on the operator's machine.

### Smoke tests

```
fhctl smoke --env pre                          # canned end-to-end checks
fhctl smoke --env pre --suite=auth             # subset
```

Suites:
- `auth` — `POST /auth` with a known test account → expect 200 + JWT
- `sync-ping` — `POST /sync/ping` with a test pharmacy → expect 200
- `pwa-load` — load `/`, verify HTML contains expected `<title>`
- `mqtt-roundtrip` — publish a `nop` message, expect echo on response topic

### Inspection helpers (for agents in particular)

```
fhctl what-is-running md-core --env pre        # one-line summary for agent prompts
fhctl recent-changes --env pre --since=24h     # which services were redeployed in the last day
fhctl context                                  # what fhctl thinks is happening: env, ctx, kubeconfig path
```

### Audit & history

```
fhctl audit                                    # local audit.log of fhctl-issued mutations
fhctl audit --since=7d --who=$USER --env=pre
```

Backed by `~/.fhctl/audit.log` — newline-delimited JSON, each entry: timestamp, user, command, target env, target service, result, exit code.

## How an LLM agent uses this

The `--json` discipline is the contract. An agent can:

```bash
# Discover capabilities
fhctl describe --json

# Find out what's where
fhctl status --env pre --json | jq '.services[] | select(.warnings | length > 0)'

# Decide whether to act
fhctl health --env pre --json
# (exit code = signal; JSON = detail)

# Take a low-risk action confidently
fhctl logs md-core --env pre --since=15m --grep ERROR --json

# Propose a high-risk action — but ALWAYS run it with --dry-run first
fhctl deploy md-core main.247 --env pre --dry-run --json
# → returns the planned actions, the gates that pass/fail, and the projected diff
# Agent shows that to the human; only proceeds if approved.
```

The `--dry-run --json` combination is the single most important affordance for agents: it returns "what would happen" as a structured object, suitable for a confirmation prompt rendered in the agent's UI.

### Suggested agent guardrails

Built into fhctl:

- `--env pre` always requires `--yes`. There is no way to mutate prod without it.
- `--json` mode prints **only** JSON to stdout (banners, spinners, etc. go to stderr) — agents can parse without a fragile separator.
- Any mutation logs a `pre-action` and `post-action` entry to `audit.log` plus stderr — even with `--json`, the agent sees what happened.
- `fhctl deploy --env pre` without `--yes` exits nonzero with `{"error": "missing --yes for prod env"}` — explicit, parseable, no surprises.

## MVP feature set (priority order)

If implementing in stages, ship in this order. Each stage is independently useful.

| Stage | Commands | Why first |
|---|---|---|
| **0 — Read-only** | `describe`, `status`, `health`, `images`, `logs`, `context`, `what-is-running`, `recent-changes`, `audit` | Zero risk; replaces a dozen bookmarks and shell aliases. Builds operator trust. |
| **1 — Tag ops** | `tag`, `images --resolve` | Replaces the unsafe hardcoded-credential `add_tag.sh`. Useful immediately. |
| **2 — Deploy/rollback (dev only)** | `deploy --env dev-0`, `rollback --env dev-0`, `apply --env dev-0` | Exercise the gates with low blast radius. |
| **3 — Smoke tests** | `smoke` | Now `deploy` can run smoke tests post-deploy automatically. |
| **4 — Production** | `deploy --env pre`, `rollback --env pre`, `release` | Ship only after stages 0-3 have been used in anger and the gates feel right. |
| **5 — DB & certs** | `db ...`, `certs ...` | Higher complexity; lower frequency. |

## Open design questions

- **Where does fhctl get its config?** Bundled defaults shipped in the binary, plus user override file, plus per-repo `.fhctl.yaml`? Probably yes to all three.
- **Audit log centralization?** Local file is the v0. v1 might POST to the version tracker or to a small audit collector. Keep local-only until pain demands centralization.
- **Multi-cluster federation?** If a third cluster (real-prod, eventually) joins, the env list grows but commands stay the same. The design accommodates this without changes.
- **Should `release` block on workflow completion?** Default yes, with `--no-wait` for fire-and-forget. Agents tend to want completion signal.
- **Plug-in architecture?** Probably not for v1. Keep the surface small and curated.

## What this design intentionally does not do

- Build images. CI does that.
- Render Slack messages prettily. They're audit signals, not UX.
- Provide a TUI. The CLI surface plus `--json` is enough; pipe to `fzf` if you want interactivity.
- Manage Postgres schema migrations. Flyway does that on pod boot.
- Write its own RBAC. Inherits whatever your kubeconfig grants you.

## Estimated implementation effort

Rough order-of-magnitude (single engineer):

- Stage 0 (read-only): 1–2 weeks
- Stage 1–2: 1 week
- Stage 3–4: 1–2 weeks
- Stage 5: 1 week
- Polish, packaging, brew tap, docs: 1 week

≈ 5–7 weeks for a complete v1. Stage 0 alone is worth shipping in week 2.
