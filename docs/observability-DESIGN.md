# Observability layer — design

Status: **draft, in-progress** — branch `feature/observability-rules-and-dashboards`.

This document covers the alerting and dashboarding layer added on top
of the existing Loki + Vector pipeline (see
[`INFRASTRUCTURE.md`](INFRASTRUCTURE.md) for the data plane). It
codifies the decisions taken on 2026-05-08 and the format that
LogQL queries must follow to "travel" between three consumers:

1. The cookbook for humans (`docs/loki/queries.md`)
2. **Loki Ruler** — evaluates LogQL alerting rules on a schedule
3. **Perses** — renders LogQL dashboards

The runtime stack we are adding to the platform droplet:

| Component | Role | Container |
|---|---|---|
| Loki Ruler (built into Loki monolithic) | LogQL → fires alerts | already running, just needs config + rule files |
| Alertmanager | Routes/groups/silences alerts → Slack `#circupack` | new container in `platform/docker-compose.yml` |
| Perses | LogQL → dashboards | new container, behind Caddy basic-auth at `dashboards.platform.fmd.fagorhealthcare.com` |

Grafana OSS is not used. The Loki Ruler + Alertmanager + Perses split
keeps each component small and single-purpose. If operating three
containers becomes a burden, switching to Grafana OSS later is
straightforward (same LogQL).

## The "queries can travel" principle

The cookbook in `docs/loki/queries.md` mixes two layers in every
entry: the LogQL kernel (portable) and shell post-processing with
`jq`/`awk` (CLI-only, not portable). Only the LogQL kernel can become
a panel or an alert. So:

- **Cookbook stays as-is.** It remains the narrative source for
  forensic investigation queries and ad-hoc exploration. Entries
  whose post-processing cannot be expressed in LogQL (e.g. message-
  prefix grouping with `cut -c1-100`) live ONLY here.
- **A query graduates to YAML** when it has a stable enough
  expression to power a panel and/or an alert. Cookbook entry then
  links to the YAML file.

## Source-of-truth schema

One YAML file per query, in `platform/observability/queries/`. Schema:

```yaml
id: <stable-snake-case-id>           # used as filename and as alert/panel id
title: <human-readable>              # shown in dashboards & alert annotations
description: |
  Multi-line context. What this query detects, why it matters,
  link to the incident or doc that motivated it.
runbook: <relative path to docs/loki/queries.md or docs/INCIDENTS.md>

# Logical scope. One YAML file per (cluster, query). When the same
# logical query applies to multiple clusters, duplicate the file with
# different cluster value — keeps alert noise scoped, simplifies
# silencing.
cluster: pre | dev-0

# The LogQL expression. Must return a metric (instant vector) for
# the alert path to work. For a logs panel without alert, see the
# `panel.type: logs` case below.
expr: |
  <LogQL>

unit: req/s | ratio | seconds | count       # used by Perses Y-axis

# Optional. Omit if the query is panel-only.
alert:
  name: <PascalCaseAlertName>
  for: <duration>                # how long the condition must hold
  condition: "> 0.05"            # threshold appended to expr at render time
  severity: warning | critical
  summary: <one-line for Slack>

# Optional. Omit if the query is alert-only.
panel:
  dashboard: <dashboard-id>      # which Perses dashboard hosts this panel
  type: timeseries | logs | table | stat
  legend: "{{label}}"            # series naming template
  thresholds:                    # color thresholds on the chart
    - { value: 0.02, color: yellow }
    - { value: 0.10, color: red }
```

### Why one file per (cluster, query)

We chose this over `clusters: [pre, dev-0]` so that:
- Alerts fire per cluster with their own label set
- Silencing one cluster is a single-line operation in Alertmanager
- Promoting an alert from dev-0 to pre is a file copy, not a flag flip

Trade-off: duplication of expressions for cross-cluster queries. We
absorb this for now; if the catalog grows past ~30 queries we will
reconsider with a templated DRY mechanism.

## Layout

```
platform/observability/
├── queries/                 # SOURCE OF TRUTH (humans edit here)
│   ├── catalog.yaml         # stable id ↔ file index, ownership
│   ├── pre/
│   │   ├── ingress-504-rate.yaml
│   │   ├── md-core-error-rate.yaml
│   │   └── actualizacion-timeout-rate.yaml
│   └── dev-0/
│       └── ...
├── render.py                # generator — ~80 LOC
├── ruler/                   # GENERATED, COMMITTED — Loki Ruler reads here
│   └── fake/rules.yaml      # `fake` = single-tenant directory
└── perses/                  # GENERATED, COMMITTED — Perses provisions from here
    └── dashboard-*.yaml
```

Generated outputs **are committed** to the repo. The platform droplet
deploys via `git pull`; committing the outputs avoids needing Python
+ PyYAML on the droplet and makes the deployable artifact visible in
PRs. CI runs `python render.py --check` to fail PRs that forget to
regenerate (it diffs committed outputs against fresh rendering).

## Generator (`render.py`)

Inputs:
- All YAML files under `queries/`
- A list of dashboard IDs collected from `panel.dashboard` fields

Outputs:
- `ruler/rules.yaml` — a single Loki Ruler file with one
  `groups[]` entry per cluster, containing all alerts for that
  cluster. Format is Prometheus-compatible (which Loki Ruler accepts
  as-is).
- `perses/dashboard-<id>.yaml` — one Perses Dashboard per
  `panel.dashboard` value, with all panels that target that dashboard.

The generator is intentionally minimal. It does NOT:
- Validate that LogQL expressions parse (Loki itself will reject bad
  rules at reload time — surfaces early enough).
- Handle templating beyond simple string formatting.
- Emit the `Datasource` object (Perses datasources are bootstrapped
  separately, once per project).

## Deployment plan (NOT in this branch)

A follow-up branch will:

1. Add Alertmanager + Perses containers to `platform/docker-compose.yml`,
   wired through Caddy with basic-auth.
2. Add Ruler config to `platform/loki/loki.yaml`, mount `ruler/`.
3. Add a `make rules` / `make dashboards` target (or Makefile-equivalent
   shell script) that runs `render.py` and copies outputs into the
   running stack via SCP + `docker compose kill -s HUP loki` and
   `percli dac apply`.
4. Add a smoke-test alert (`AlwaysFiring`) to verify Slack delivery.

This branch only ships the schema, the generator, and the first
graduated query — `actualizacion-timeout-rate` — derived from the
2026-05-08 incident.

## Open questions

- **Multi-tenant Loki**: today our Loki runs in single-tenant mode
  (`auth_enabled: false`). Ruler defaults to tenant `fake`. If we
  later turn on multi-tenancy, rule files move to per-tenant
  subdirectories. Not blocking for v1.
- **Alertmanager state**: Alertmanager keeps silences and notification
  state on disk. Mount a small volume (`alertmanager_data`) so silences
  survive container restarts. Not Spaces-backed — the data is
  ephemeral by nature (worst case: re-create silences after restart).
- **Perses persistence**: Perses can run with file-based storage
  (the dashboards we push) or with a database. We start with files
  because it suits the "everything is in git" workflow.
