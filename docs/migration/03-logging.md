# Pillar 03 — Vector → Loki

Status: **proposed** | Estimated savings: **−$70/mo (~€65)** | Effort: **~1 day implementation + 30 days parallel run** | Risk: **low–medium** | Depends on: **[06-platform-tier.md](06-platform-tier.md)** (Loki runs on the platform droplet)

Replace the AWS Elasticsearch sink with a self-hosted **Grafana Loki**
instance backed by DO Spaces. Loki runs as a service in the platform
droplet's `docker compose` stack (see [06-platform-tier.md](06-platform-tier.md)) —
**not** in either app cluster. Vector — including all the existing
parsing logic for Nginx, Quarkus JSON, and the
`:U…:B…:T…:S…:P…:` regex — stays untouched. Only the sink block changes.

## Motivation

- AWS Elasticsearch costs ~€70/mo for a service we use poorly:
  **218 MiB total cluster usage on 49 GiB allocated** (0.4% utilisation).
  We cannot scale the AWS tier any smaller without dropping below
  operational viability — we are paying for the smallest reasonable
  production-shape ES domain regardless of actual volume.
- Logs are operational, not regulatory. We do not need the per-field
  indexed search of Elasticsearch — `grep`-shaped LogQL is sufficient
  for incident response.
- Grafana already has mind-share inside the team (no current install,
  but the LogQL → Grafana Explore workflow is easier to onboard than
  Kibana for greenfield users).
- Loki's cost model (cheap object storage, expensive index labels)
  matches our use case: low service count, low log line volume.
- **The current AWS ES pipeline silently drops logs.** There are
  **11 `failed-medicaldispenser-*` indices** in AWS ES, dispersed
  across **December 2025 – May 2026**, indicating intermittent ingest
  failures the AWS-side pipeline didn't recover from. See "Reliability
  improvement" below for how Loki + Vector mitigates the *transport*
  side of this; VRL parse errors will still need verification
  post-cutover.

## Target architecture

### Vector config — minimal diff

The whole change to `k8s/environments/dev-0/vector/vector.yaml` (and
the equivalent under `pre/`) is replacing the `gailen_elk_dev` sink:

```yaml
# DELETE:
# sinks:
#   gailen_elk_dev:
#     type: elasticsearch
#     endpoint: https://search-dev-elk-...es.amazonaws.com
#     pipeline: medicaldispenser
#     mode: bulk
#     bulk:
#       index: medicaldispenser-dev-%Y-%m-%d
#     auth:
#       strategy: basic
#       user: dev-elk
#       password: _d3vELK_

# ADD:
sinks:
  loki:
    type: loki
    inputs: [kubernetes_clean_logs]
    endpoint: https://logs.platform.fagorhealthcare.com
    encoding:
      codec: json
    labels:
      service: '{{ kubernetes.container_name }}'
      namespace: '{{ kubernetes.pod_namespace }}'
      env: dev   # or "pre" in pre's vector.yaml
      level: '{{ level }}'
    out_of_order_action: accept   # safe under chunked ingestion
    buffer:
      type: disk
      max_size: 2147483648   # 2 GiB on-disk buffer per Vector pod
      when_full: drop_newest
```

Everything else — `parse_nginx_log`, JSON merging, the
`:U(?P<user>...):B(?P<blister>...):T(?P<treatment>...):S(?P<seguimiento>...):P(?P<phone>...):`
regex extraction, the `kube-probe` filter — runs identically. Vector
emits the same enriched event to Loki that it sends to ES today.

### Reliability improvement vs current AWS ES pipeline

The 11 `failed-medicaldispenser-*` indices in AWS ES (Dec 2025 –
May 2026) tell us the existing ingest pipeline silently drops events
during transient ES unavailability or backpressure. Loki + Vector
mitigates the *transport* layer:

- **Vector's on-disk buffer** (`buffer.type=disk`, 2 GiB) holds events
  if Loki is unreachable, retrying with exponential backoff for hours
  before any drop occurs. Today's pipeline drops on the AWS-side
  bulk-API rejection without Vector noticing.
- **Vector's `out_of_order_action: accept`** matches Loki's chunk
  ingestion model and avoids the per-shard ordering rejections that
  plague ES bulk ingest under retry storms.

What this *does not* fix: VRL parse failures inside Vector itself
(a malformed regex, a JSON field with an unexpected type) still drop
events at the transform stage. Track `vector_component_errors_total`
after cutover and add a Grafana alert before declaring the migration
done.

### The conceptual shift: labels vs log line

This is the part to internalise before writing queries.

- **Elasticsearch** indexes every field equally.
  `{"term":{"user":"alice"}}` is fast because `user` has an inverted
  index entry per value.
- **Loki** splits the world into:
  - **Labels** (low cardinality, indexed) — `service`, `env`,
    `namespace`, `level`. These are the only values used to *find*
    a log stream.
  - **Log line content** (high cardinality, NOT indexed) — `user`,
    `phone`, `blister`, `treatment`, `seguimiento`. These are domain
    identifiers. Putting them in labels would create one stream per
    unique value, which would explode Loki's index and is the
    canonical Loki anti-pattern.

The query model swaps from "match anything anywhere" to **"narrow by
labels first, then filter the line"**:

| Need | Elasticsearch DSL | LogQL |
|---|---|---|
| All `md-core` errors today | `{"term":{"kubernetes.container_name":"md-core"}, "term":{"level":"ERROR"}}` | `{service="md-core", level="ERROR"}` |
| Logs for user `alice` | `{"term":{"user":"alice"}}` | `{service="md-core"} \| json \| user="alice"` |
| Phone-number search | `{"term":{"phone":"+34..."}}` | `{service="md-core"} \| json \| phone="+34..."` |
| Blister `B-1234` activity | `{"term":{"blister":"B-1234"}}` | `{service="md-core"} \| json \| blister="B-1234"` |

The `\| json` stage parses the JSON line into ad-hoc fields at query
time; since Vector already emits enriched JSON with `user`, `phone`,
etc., LogQL can filter on them without any of them being indexed
labels.

### Storage layout

- **Loki monolithic mode** (single binary, single docker-compose
  service, replica 1). Serious enough for our scale; sharding is
  unnecessary at ~5 MiB/day compressed.
- **`tsdb`** index, **chunks** in DO Spaces (`platform-logs` bucket,
  `fra1`).
- **Local volume of 10 GiB** on the platform droplet, mounted at
  `/loki` for the write-ahead log (chunk buffer before flush) and the
  local index cache. 10 GiB is generous; 5 GiB would suffice. Lives
  on the droplet's root disk.
- **Retention**: `limits_config.retention_period = 8760h` = **365 days**.
  Compactor runs with `retention_enabled: true` and deletes expired
  chunks from Spaces.

### Volume estimate — measured, not guessed

Real numbers from the live AWS ES domain:

| Metric | Value |
|---|---|
| Total cluster usage today | **218 MiB** |
| Daily raw input | **~25 MiB/day** |
| Daily Snappy-compressed (Loki chunk format) | **~5 MiB/day** |
| 365-day projection (compressed) | **~1.8 GiB/year** |

DO Spaces' $5/mo base unit includes 250 GiB. We use 1.8 GiB in year 1.
After 5 years at constant volume: ~9 GiB. **Even 10× growth** (e.g.
WhatsApp DEBUG enabled enterprise-wide) keeps us inside the included
quota with 90% headroom.

This is why the retention decision is **365 days** by default. At our
volume, retention is essentially free up to several years. If a
regulatory question ever turns up requiring 5+ year retention, we
extend `retention_period` to `43800h` and the monthly bill does not
move.

The `platform-logs` bucket and the `platform-registry` bucket together
share one $5/mo base unit. Counted in pillar 06.

### UI

For v1 we use **Grafana Cloud's free tier** (10 k metrics + 50 GB
logs included) as the query frontend, pointing at the self-hosted
Loki via the public `https://logs.platform.fagorhealthcare.com`
endpoint. No Grafana pod to operate.

If Grafana Cloud's free tier ever becomes insufficient, drop a
`grafana` service into the platform droplet's `docker compose` stack
and add a `grafana.platform.fagorhealthcare.com` Caddy route. Out of
scope for v1.

Kibana access for AWS ES stays available during the parallel run.

## Cost delta

| Change | Monthly delta |
|---|---|
| AWS Elasticsearch domain canceled | **−€70 (~−$77)** |
| DO Spaces (`platform-logs`, ~2 GiB) | **+$0** (shares the $5 Spaces base unit with `platform-registry`; counted in pillar 06) |
| Local 10 GiB volume (Loki WAL on the droplet's root disk) | **$0** (in the droplet's included storage) |
| Loki service compute | **$0** (runs in the platform droplet's compose stack — see pillar 06) |
| Grafana Cloud free tier | **$0** |
| AWS S3 IA backup (~2 GiB) | **+$0.50** |
| **Net** | **~−$70/mo** |

The platform droplet hosting cost is accounted in pillar 06, not here,
to avoid double-counting.

## Work breakdown

### Day 1 — Implementation (~1 day, on top of pillar 06)

- Add `loki` service to `/opt/platform/docker-compose.yml` (skeleton
  in pillar 06).
- Author `loki-config.yaml` with the S3 backend pointing at
  `platform-logs` (skeleton in pillar 06).
- Add the `logs.platform.fagorhealthcare.com` block to the `Caddyfile`.
- `docker compose up -d loki caddy && docker compose logs -f loki` to
  watch the first start.
- Add a *second* Vector sink in both clusters' `vector.yaml`, pointing
  at `https://logs.platform.fagorhealthcare.com`. Keep the AWS ES sink
  during the parallel run.
- Configure Grafana Cloud free tier with a Loki datasource pointing
  at the public endpoint. Add HTTP basic auth on the Caddy side first
  if exposing public read access feels wrong (`zot` already uses
  htpasswd, copy the same pattern).
- Validate in Grafana Explore: search for a known log line, verify
  `level`, `service`, `user`, `phone` filters work.

### Days 2–30 — Parallel run

- Vector writes to both ES and Loki every day.
- Spot-check daily: pick yesterday's incident-y looking log in Kibana,
  reproduce the same query in Grafana Explore. They should agree.
- Watch Loki's `loki_distributor_bytes_received_total` against AWS ES
  index growth — they should track within ~10%.
- Watch `vector_component_errors_total{component_id="parse_*"}` for
  any parse-stage drops that the AWS ES side may have masked.

### Day 31 — Cutover

- Remove the `elasticsearch` sink from both `vector.yaml`s, leaving
  only `loki`.
- Stop the AWS Elasticsearch domain (do not delete yet — keep the
  snapshot for ~7 days as insurance).
- After a week of clean Loki-only operation, delete the AWS domain.
- The `dev-elk:_d3vELK_` credential dies naturally with the AWS ES
  domain. No active rotation needed (decision deferred until cutover —
  see "Risks and gotchas" below).

### Documentation

- Update `docs/INFRASTRUCTURE.md` ("Logging" section) in this repo to
  reflect Loki, query examples, retention, and the
  labels-vs-line-content shift.
- Add a one-page LogQL cheat-sheet to `docs/OPERATIONS.md` covering
  the five most common queries.

## Risks and gotchas (honest list)

- **Historical AWS ES data does NOT migrate.** Loki starts empty on
  cutover day. If anyone needs ES data from before, they query Kibana
  during the parallel window. Acceptable: logs are operational, not a
  regulatory archive (medical device regulatory data lives in Postgres).
- **LogQL is a learning curve** for anyone who only knows Kibana.
  Plan a 30-minute team walkthrough before cutover. Document the
  Kibana → LogQL translations for the queries we actually run.
- **`dev-elk:_d3vELK_` credential rotation deferred until cutover.**
  The credential gates write access to a domain we are about to delete.
  Rotating it now is busy-work that touches every Vector ConfigMap
  for nothing — the credential dies the moment the AWS ES domain is
  stopped. Residual risk: if the credential leaks during the
  ~30-day parallel-run window, an attacker can write spam events into
  AWS ES, which we are reading from but will discard at cutover. This
  is acceptable. Document the decision and proceed.
- **Cross-cluster ingest from `pre` → platform droplet** travels over
  public internet (TLS terminated at Caddy). Same path Vector uses
  today to reach AWS ES. No new risk; rate-limit Vector's retry policy
  as a cheap safety belt.
- **Cardinality footguns** to flag in code review: `pod` and
  `pod_uid` are kubernetes-native labels Vector exports by default.
  Strip them before sending to Loki, otherwise pod restarts multiply
  stream count. Use `labels.namespace`/`labels.service`/`labels.env`/
  `labels.level` and nothing else as labels.
- **Loki single-replica means a Loki crash drops in-flight WAL** until
  the service restarts. The 10 GiB local volume catches this on disk;
  the only true data loss window is the seconds between Vector's last
  flush and the crash. With Vector's 2 GiB on-disk buffer in front,
  even a multi-hour Loki outage queues rather than drops.
  Acceptable for ops logs. If we ever want HA, see "Out of scope for
  v1" in pillar 06.
- **Platform droplet is a single point of failure for log ingest.**
  See pillar 06's "Honest gotchas" — Vector's disk buffer is the
  primary mitigation.
- **VRL parse failures still need verification post-cutover.**
  See "Reliability improvement" above. Loki + Vector fixes the
  transport-side silent drops we saw in AWS ES; parse-side drops
  recur identically.

## Integration with `fhctl`

The `internal/es/client.go` semantics — search by `--user`, `--phone`,
`--blister`, `--treatment`, `--seguimiento`, `--query`, free-text
across the message body — translate cleanly to LogQL pipelines:

```
fhctl logs --service md-core --user alice --since 24h
  ↓
{service="md-core"} | json | user="alice" | __error__=""
```

Estimated effort: **~150 LOC** new client (`internal/loki/client.go`
implementing the same search interface as `internal/es/client.go`),
**~50 LOC** of integration registration following Phase H's pattern.
Mechanical — same flag surface, different wire protocol. Listed as
follow-on, not a blocker for this pillar.

## Done when

- [ ] Platform droplet (pillar 06) is up and `logs.platform.fagorhealthcare.com` resolves to it
- [ ] Loki running on the droplet, fronted by Caddy, S3 backend
      pointing at `platform-logs`
- [ ] Grafana Cloud free tier configured with the Loki datasource
- [ ] Vector in both clusters writes to Loki (and to AWS ES during the
      parallel window)
- [ ] At least 30 days of parallel-run data, spot-checked
- [ ] AWS Elasticsearch sink removed from `vector.yaml`
- [ ] AWS Elasticsearch domain stopped (then deleted ≥7 days later)
- [ ] `md-backup` extended with the `rclone sync` step (logs portion)
      and the AWS S3 `/logs/` lifecycle policy applied
- [ ] `INFRASTRUCTURE.md` and `OPERATIONS.md` updated with Loki +
      LogQL
- [ ] Team walkthrough delivered, LogQL cheat-sheet linked
- [ ] `vector_component_errors_total` baseline captured; any
      parse-stage drops triaged
