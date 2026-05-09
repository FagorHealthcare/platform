# Observability MCP — design sketch

**Status**: design proposal, not implemented. Captures the decisions
taken in the conversation of 2026-05-09 so a future iteration starts
from concrete choices, not from scratch.

This doc describes an **MCP (Model Context Protocol) server** that
exposes the Loki/Alertmanager observability stack as a fixed set of
tools an LLM client (Claude Code, Claude Desktop, Cursor, etc.) can
call. The goal is to let the LLM run the same kind of investigations
documented in [`docs/loki/queries.md`](loki/queries.md) without us
re-explaining the tooling each session.

## Goal

Move the cookbook entries (#01–#25 in `docs/loki/queries.md`) from
"recipes a human pastes into a terminal" to "tools an LLM can pick
from a menu and parameterise". Result: an LLM agent can answer
questions like *"qué blisters están más activos hoy"*, *"dame todos
los errores del paciente con teléfono X"*, *"hay alertas firing"* by
calling typed tools, getting structured responses, and chaining them.

## Non-goals (v1)

- **No write operations**. No silences, no rule edits, no
  `add_recipe`. Read-only sandbox. Adding a recipe = a human PR to
  the YAML catalog and an MCP restart.
- **No exposed Loki proxy**. The MCP doesn't forward arbitrary HTTP
  to Loki — it issues queries via `logcli` (or an internal client)
  and returns structured results. Avoids leaking Loki internals.
- **No multi-tenant**. One stack (`pre`), one Loki, one set of creds.
  Multi-cluster comes later if it pays off.
- **No streaming / tail**. Single-shot queries only. `tail -f` style
  doesn't fit the request/response shape of MCP tool calls.

## Constraint that drives the design: MCP tool list is fixed per session

The MCP protocol exposes tools via `tools/list` at session init.
Tools cannot be discovered dynamically inside a conversation. So the
design splits the surface into:

1. **A small fixed set of tools** (7 in v1) covering the canonical
   operations.
2. **A YAML-driven "recipes" catalog** that one of those tools
   (`loki_run_recipe`) executes. Adding a recipe doesn't change the
   tool surface — only the menu that `loki_list_recipes()` returns.

This is the same pattern as a "scripting tool" + "function library"
in classical IDE ergonomics, applied to LLM tool calls.

## Constraints (v1 scope)

- **Deployment**: runs on the platform droplet (`md-platform`,
  `161.35.222.77`), alongside Loki/Alertmanager/Perses in
  `/opt/platform/stack/`.
- **Auth**: reads Loki creds from
  `terraform/platform-credentials.txt`, mounted into the container
  at runtime. Same secret already used by other components on the
  droplet.
- **Network**: bound to `127.0.0.1` on the droplet. Exposed via
  Caddy with basic-auth at
  `https://mcp.platform.fmd.fagorhealthcare.com/` (DNS record TBD).
  No public ingress without auth.
- **Read-only**: no shell, no filesystem write, no git ops.

## Tool surface (v1, 7 tools)

```
loki_list_recipes()
  → returns: [{id, description, params, since_default}, ...]
  Lists every recipe in the catalog. Always called first by an LLM
  that doesn't yet know what's available.

loki_run_recipe(id, params, since?)
  → returns: { summary, rows[], truncated, next_steps_hint[] }
  Executes a recipe by id with the given params. Recipes are
  defined in YAML (see "Recipes catalog" below).

loki_drill_field(field, value, since?, limit?)
  → returns: { rows: [{ts, level, message}], truncated }
  field ∈ { blister, phone, treatment, seguimiento, user }
  Generic drill-down: every md-core log line where the given MDC
  field equals `value`. Implements recipe #21 directly without
  needing the recipes layer.

loki_top_field(field, since?, limit?)
  → returns: { rows: [{value, count}], total_distinct, truncated }
  Top N values for a given MDC field. Implements recipe #20.

loki_query(expr, since?, limit?, jq?)
  → returns: { rows[], truncated, warnings[] }
  Escape hatch. Runs raw LogQL and optionally a jq post-process. By
  default does NOT add `| json` server-side (see "Known problems"
  below). The LLM uses this when no recipe fits.

am_list_alerts(state?)
  → state ∈ { firing, pending, silenced } (default: firing)
  → returns: [{ alertname, labels, annotations, startsAt }, ...]
  Snapshot of Alertmanager state.

am_describe_alert(alertname)
  → returns: { rule_yaml, runbook_url, recent_firings[] }
  Joins the rule definition (from Loki Ruler) with the recent
  firing history (from AM). Used when investigating *why* an alert
  is configured the way it is.
```

## Recipes catalog

Reuses the existing
[`platform/observability/queries/catalog.yaml`](../platform/observability/queries/catalog.yaml)
and per-query YAMLs as the **single source of truth**. Two
consumers:

- `render.py` → emits Loki Ruler rules + Perses dashboards (today).
- MCP server → loads recipes for `loki_list_recipes` and
  `loki_run_recipe` (new).

A recipe entry needs slightly more than what the existing catalog
carries. Proposed extension to the per-query YAML:

```yaml
id: top-blisters
title: Top blisters by event count
description: |
  Returns the most active blisters in a time window. Useful as a
  starting point when investigating "what's busy right now".
runbook: docs/loki/queries.md#20

cluster: pre

# --- existing fields (used by render.py for alerts/panels) ---
expr: |
  {cluster="pre", container="md-core"}
unit: count
panel: { ... }

# --- new fields (used by MCP only) ---
mcp:
  recipe: top-blisters         # opt-in: only catalog entries with `mcp:` are exposed
  params:
    since: { type: duration, default: "24h", min: "5m", max: "30d" }
    limit: { type: int,      default: 20,    min: 1,    max: 200 }
  postprocess: |
    .line | fromjson? | .blister // empty | select(. != "-")
  aggregate: count_descending
  schema:
    rows: [{ blister: string, count: int }]
  next_steps:
    - { recipe: drill-blister, params: { blister: "{{rows[0].blister}}" } }
    - { recipe: top-field,     params: { field: phone } }
```

Rationale:

- `mcp.recipe` is opt-in so that not every panel becomes an MCP
  tool. Only those whose semantics are clean for an LLM (returns a
  small structured table, not a time-series dump).
- `params` carry types + bounds. The MCP rejects out-of-bound calls
  with a helpful error before hitting Loki.
- `postprocess` is the jq pipeline — same one that worked in the
  cookbook, so debugging stays one place.
- `next_steps` are recipe ids the LLM can chain. Server populates
  `next_steps_hint[]` in the response after templating.

## Response shape (LLM-friendly)

Every tool returns a structured JSON object designed for token
efficiency and chaining:

```json
{
  "ok": true,
  "summary": "237 distinct blisters in 30h, top 20 below",
  "rows": [{"blister": "TX5CAA", "count": 46}, ...],
  "truncated": false,
  "warnings": [],
  "next_steps_hint": [
    {"recipe": "drill-blister", "params": {"blister": "TX5CAA"}}
  ]
}
```

- `summary` is a one-liner the LLM can quote back to the user
  without parsing rows.
- `rows` is normalised — never raw `logcli` JSONL. Schema declared
  in the recipe.
- `truncated: true` flag if the underlying query hit `limit` —
  prevents the LLM from drawing wrong conclusions from a partial
  view.
- `warnings[]` for soft failures (recipe matched but returned 0
  rows, query took >5s, etc).
- `next_steps_hint[]` is a soft suggestion — purely advisory.

## Deployment plan

1. New service in
   [`platform/docker-compose.yml`](../platform/docker-compose.yml):
   `obs-mcp`, image built from `platform/mcp/Dockerfile`.
2. Read-only mounts: `platform/observability/queries/` (recipes
   catalog), `platform/credentials/loki-auth.txt` (creds — already
   used by other services).
3. New Caddy vhost in
   [`platform/caddy/Caddyfile`](../platform/caddy/Caddyfile):
   `mcp.platform.fmd.fagorhealthcare.com → obs-mcp:8080` with
   basic-auth and per-route allowlist (no writes from outside).
4. New DNS record in [`terraform/dns.tf`](../terraform/dns.tf):
   `mcp.platform` → reserved IP.
5. The LLM client (Claude Code, Cursor, etc.) connects via the
   MCP-over-HTTP transport with the basic-auth header.

## Known problems and gotchas

Things this design must handle from day one because we already hit
them in the cookbook:

### 1. Vector's nested `kubernetes` object breaks server-side `| json`

LogQL filter `| json | blister="X"` returns 0 rows in our setup
because the nested `kubernetes` object confuses Loki's json parser.
This was discovered live on 2026-05-09 (see `docs/loki/queries.md`
"Tip" section).

**Implication for MCP**: `loki_query` must default to *not* applying
`| json` server-side. The recommended pattern is fetch raw + jq
client-side in the MCP. Document this in the tool description so
the LLM doesn't re-derive it.

### 2. MDC `blister` field carries two id schemas

`com.medicaldispenser.shc.http.ShcController` logs use a numeric
device-local id (0, 837, 1168, …); the rest of md-core uses the
6-char alphanumeric token (H7BXCI, JC1PKZ, …). See
`docs/loki/queries.md` "Hallazgo A" 2026-05-09.

**Implication for MCP**: `loki_drill_field(field=blister, value=X)`
will silently miss SHC events for the same physical blister
because the id space differs. Document in the tool description and
return a `warnings[]` entry when the value matches the alphanumeric
shape but no SHCEvent rows came back.

### 3. Token budget — raw `output=jsonl` is wasteful

Every Loki line carries the full `kubernetes.*` object (~1.5 KB of
labels, annotations, image hashes, pod_ip, etc). At ~8500
md-core lines/day, an unfiltered `since=24h` query approaches 13 MB.
Way too big for an LLM context.

**Implication for MCP**: every tool must apply post-processing
**before returning**. Default response carries `[ts, level, message,
blister, phone, treatment, user]` — nothing else. The full raw line
is available as opt-in (`include_raw: true`) for debugging.

### 4. Latency — `logcli` round-trip is 1–3s

Each query goes platform droplet → Loki → S3 backend (chunks). For
the LLM that's a perceptible pause per tool call. Caching is hard
because `since=` shifts every minute.

**Implication for MCP**: tool descriptions should encourage batching
(e.g., `top_field` + `drill_field` in two calls is fine, ten
exploratory `loki_query` calls per turn is wasteful). Add a
`max_calls_per_minute` sanity throttle.

### 5. Cardinality — `top_field` over long windows can OOM Loki

`since=30d` on a high-cardinality field (`phone`, `blister`) hits
Loki's series limit (`maximum of series (500) reached`).

**Implication for MCP**: enforce `since` upper bound (30d hard cap),
return `warnings[]` if the underlying query came back partial, and
suggest `since=24h` in the tool description as the default.

### 6. Auth secret on disk is gitignored — easy to forget

`terraform/platform-credentials.txt` is gitignored. A fresh droplet
deploy needs that file dropped in by hand. If missing, the MCP
silently returns 401 from Loki for every call.

**Implication for MCP**: on startup, the server should make a probe
call (`logcli labels`) and exit non-zero if auth fails. Don't run
in a degraded state where every tool errors.

### 7. The recipes YAML and Perses dashboards live in the same
file

If we extend `queries/<id>.yaml` with `mcp:` blocks, `render.py`
must ignore them. Already does (it only consumes `expr`, `alert`,
`panel`, `threshold`). Confirmed safe by inspection of
`platform/observability/render.py` after the 2026-05-09 refactor.

But the inverse risk exists: if a recipe expects a different
post-processing than what the panel shows, the LLM and the human
get different answers from the "same" query id. **Mitigation**:
recipes that need different semantics get a separate id (don't
overload the panel id).

## Open questions for v2

- **Write tools**: would `am_silence` (with required justification +
  audit log) be worth adding? Probably yes once the MCP has
  demonstrated value read-only for a few weeks.
- **`add_recipe` tool**: lets Claude propose a new recipe by
  writing a YAML and opening a PR. High UX value, but git ops in an
  MCP add a lot of failure modes — defer until the manual flow
  feels too slow.
- **Multi-cluster**: today only `pre`. When `dev-0` ships its own
  Loki ruler, the MCP needs a `cluster: pre|dev-0` parameter on
  every tool, and recipes that span clusters.
- **Caching layer**: a 30s memoization on `loki_top_field(field=*,
  since=24h)` would absorb a lot of redundant calls. Trade-off is
  staleness vs cost.
- **Schema for `next_steps_hint[]`**: today it's just `{recipe,
  params}`. Could carry "expected duration", "expected row count"
  to let the LLM pick the cheaper option.

## Pointers

- Tool list inspiration: existing recipes #20–#25 in
  [`docs/loki/queries.md`](loki/queries.md).
- Known query gotchas already documented in the cookbook (see "Tip:
  ver el shape completo de una línea" and "Exploración 2026-05-09").
- Catalog source of truth:
  [`platform/observability/queries/catalog.yaml`](../platform/observability/queries/catalog.yaml).
- Perses generator that already consumes the catalog:
  [`platform/observability/render.py`](../platform/observability/render.py).
- The companion fhctl design (read-only operator CLI for humans) is
  in [`fhctl-DESIGN.md`](fhctl-DESIGN.md). MCP is the LLM-facing
  sibling of fhctl.
