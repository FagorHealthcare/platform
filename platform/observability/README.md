# platform/observability — alerting & dashboarding layer

This directory holds the **source of truth** for Loki Ruler alerts and
Perses dashboards. See [`docs/observability-DESIGN.md`](../../docs/observability-DESIGN.md)
for the full design rationale.

## Layout

```
queries/                 # source of truth — humans edit here
  catalog.yaml           # stable id ↔ file index
  pre/<id>.yaml          # one file per (cluster, query)
  dev-0/<id>.yaml
render.py                # generator
ruler/fake/rules.yaml    # GENERATED, committed — Loki Ruler reads here (fake/ is the single-tenant subdir)
perses/dashboard-*.yaml  # GENERATED, committed — Perses provisions from here
```

## Local setup

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

## Day-to-day

After editing `queries/`:

```bash
.venv/bin/python render.py
```

In CI / before push:

```bash
.venv/bin/python render.py --check    # exit 1 if outputs drift from sources
```

## Adding a query

1. Decide the cluster (currently `pre` or `dev-0`).
2. Pick a stable, kebab-case id — it becomes the filename and the
   alert rule name. Once chosen, never rename it (would break alert
   history and dashboard links).
3. Drop a YAML at `queries/<cluster>/<id>.yaml` with the schema below.
4. Register it in `queries/catalog.yaml` with a one-line summary.
5. Run `render.py`.

## Query schema

```yaml
id: <stable-snake-case-id>
title: <human-readable, shown in dashboards & alerts>
description: |
  Multi-line context. Why this matters; what it detects.
runbook: <relative path to docs that explain how to respond>

cluster: pre | dev-0

expr: |
  <LogQL expression — must return a metric for alerts to work>

unit: req/s | ratio | seconds | count

# Optional. Single source of truth for the alert's firing threshold AND
# the panel's coloured guide lines. render.py derives both — they cannot
# drift. The legacy fields `alert.condition` and `panel.thresholds` are
# rejected to force the migration.
threshold:
  warning: 0.02   # alert fires here (if `alert:` block present); panel yellow line
  critical: 0.10  # panel red line (no separate alert level for now)

# Optional. Omit for panel-only queries.
alert:
  name: <PascalCaseAlertName>
  for: <duration>           # e.g. 5m
  severity: warning | critical
  summary: <one-line for Slack>
  comparator: ">"           # optional; default ">". Use "<" for low-side breaches.

# Optional. Omit for alert-only queries.
panel:
  dashboard: <dashboard-id>
  type: timeseries | logs | table | stat
  legend: "{{label_template}}"
```

See `queries/pre/actualizacion-timeout-rate.yaml` for a complete worked
example covering both an alert and a panel.

## Slack webhook (deployed state)

Alertmanager reads the webhook URL from
`/etc/alertmanager/slack-webhook.txt` (mounted from
`platform/alertmanager/slack-webhook.txt` on the droplet, gitignored).

When provisioning a fresh droplet, drop the URL into that file and
make sure it's readable by the `nobody` user:

```bash
echo 'https://hooks.slack.com/services/...' \
  > /opt/platform/stack/alertmanager/slack-webhook.txt
chmod 0644 /opt/platform/stack/alertmanager/slack-webhook.txt
```

`0640` is **not enough** — the `prom/alertmanager` image runs as
`nobody`, not as root. With wrong perms Alertmanager logs
`open /etc/alertmanager/slack-webhook.txt: permission denied` and
moves on without delivering. Worse, it then waits the full
`repeat_interval` (4h by default) before re-attempting. Recover from
that state by either waiting, or wiping the AM nflog volume:

```bash
cd /opt/platform/stack
docker compose rm -fsv alertmanager
docker volume rm stack_alertmanager_data
docker compose up -d alertmanager
```

The `channel:` field in `alertmanager.yml` is **decorative** for
incoming webhooks — Slack ignores it; the URL itself encodes the
destination channel. To change channels, regenerate the webhook in
Slack admin and overwrite `slack-webhook.txt`.

## Cookbook vs catalog

The cookbook in [`docs/loki/queries.md`](../../docs/loki/queries.md) is
the narrative for ad-hoc forensic queries. A query "graduates" to this
catalog when its LogQL kernel is stable enough to power a dashboard
panel and/or an alert. Cookbook entries that rely on shell post-processing
(`jq`, `awk`, `sort | uniq -c`) and cannot be expressed in pure LogQL
stay in the cookbook only.
