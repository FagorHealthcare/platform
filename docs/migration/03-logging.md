# Pillar 03 — Vector → Loki

Status: **proposed** | Estimated savings: **−$70/mo (~€65)** | Effort: **~1 day implementation + 30 days parallel run** | Risk: **low–medium** | Depends on: **01-rightsizing** (memory headroom for Loki)

Replace the AWS Elasticsearch sink with a self-hosted **Grafana Loki**
instance backed by DO Spaces. Vector — including all the existing
parsing logic for Nginx, Quarkus JSON, and the `:U…:B…:T…:S…:P…:` regex
— stays untouched. Only the sink block changes.

## Motivation

- AWS Elasticsearch costs ~€70/mo for log retention we control poorly
  (retention is whatever the cluster's storage allows; index lifecycle
  is undocumented).
- Logs are operational, not regulatory. We do not need the per-field
  indexed search of Elasticsearch — `grep`-shaped LogQL is sufficient
  for incident response.
- Grafana already has mind-share inside the team (no current install,
  but the LogQL → Grafana Explore workflow is easier to onboard than
  Kibana for greenfield users).
- Loki's cost model (cheap object storage, expensive index labels)
  matches our use case: low service count, high log line volume.

## Target architecture

### Vector config — minimal diff

The whole change to `k8s/environments/dev-0/vector/vector.yaml` (and the
equivalent under `pre/`) is replacing the `gailen_elk_dev` sink:

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
    endpoint: https://logs.k8s.gailen.net  # cross-cluster from pre to dev
    encoding:
      codec: json
    labels:
      service: '{{ kubernetes.container_name }}'
      namespace: '{{ kubernetes.pod_namespace }}'
      env: dev   # or "pre" in pre's vector.yaml
      level: '{{ level }}'
    out_of_order_action: accept   # safe under chunked ingestion
```

Everything else — `parse_nginx_log`, JSON merging, the
`:U(?P<user>...):B(?P<blister>...):T(?P<treatment>...):S(?P<seguimiento>...):P(?P<phone>...):` regex
extraction, the `kube-probe` filter — runs identically. Vector emits the
same enriched event to Loki that it sends to ES today.

### The conceptual shift: labels vs log line

This is the part to internalise before writing queries.

- **Elasticsearch** indexes every field equally. `{"term":{"user":"alice"}}`
  is fast because `user` has an inverted index entry per value.
- **Loki** splits the world into:
  - **Labels** (low cardinality, indexed) — `service`, `env`, `namespace`,
    `level`. These are the only values used to *find* a log stream.
  - **Log line content** (high cardinality, NOT indexed) — `user`,
    `phone`, `blister`, `treatment`, `seguimiento`. These are domain
    identifiers. Putting them in labels would create one stream per
    unique value, which would explode Loki's index and is the canonical
    Loki anti-pattern.

The query model swaps from "match anything anywhere" to **"narrow by
labels first, then filter the line"**:

| Need | Elasticsearch DSL | LogQL |
|---|---|---|
| All `md-core` errors today | `{"term":{"kubernetes.container_name":"md-core"}, "term":{"level":"ERROR"}}` | `{service="md-core", level="ERROR"}` |
| Logs for user `alice` | `{"term":{"user":"alice"}}` | `{service="md-core"} \| json \| user="alice"` |
| Phone-number search | `{"term":{"phone":"+34..."}}` | `{service="md-core"} \| json \| phone="+34..."` |
| Blister `B-1234` activity | `{"term":{"blister":"B-1234"}}` | `{service="md-core"} \| json \| blister="B-1234"` |

The `\| json` stage parses the JSON line into ad-hoc fields at query time;
since Vector already emits enriched JSON with `user`, `phone`, etc.,
LogQL can filter on them without any of them being indexed labels.

### Storage layout

- **Loki monolithic mode** (single binary, single Deployment, replica 1).
  Serious enough for our scale; sharding is unnecessary at ~10 GiB/mo
  ingestion.
- **`boltdb-shipper`** index, **chunks** in DO Spaces (`platform-logs`
  bucket, `fra1`).
- **Local PVC of 10 GiB** mounted at `/loki` for the write-ahead log
  (chunk buffer before flush) and the local boltdb shipper cache.
  10 GiB is generous; 5 GiB would suffice. Either fits within the
  pillar 01 headroom.
- **Retention**: configurable in `compactor` block. Initial target:
  **120 days**. After that, `compactor.retention_enabled=true` deletes
  expired chunks from Spaces.

### Volume estimate

- 5 services × ~2 GiB/day raw stdout (eyeballed from current AWS ES daily
  index size) = ~10 GiB/day raw.
- Snappy compression on Loki chunks: ~5×. ~2 GiB/day compressed.
- 120 days × 2 GiB ≈ 250 GiB. Well within Spaces' baseline tier price.

### UI

Grafana, single instance in the dev cluster, behind the existing
`*.k8s.gailen.net` ingress. Single Loki datasource. No alerting rules
in v1; just Explore.

Kibana access for AWS ES stays available during the parallel run.

## Cost delta

| Change | Monthly delta |
|---|---|
| AWS Elasticsearch domain canceled | **−€70 (~−$77)** |
| DO Spaces (`platform-logs`, ~250 GiB) | **+$5** |
| PVC 10 GiB (Loki WAL) | **+$2** |
| Grafana pod (~256 MiB) | $0 (uses pillar 01 headroom) |
| **Net** | **~−$70/mo** |

## Work breakdown

### Day 1 — Implementation

- Helm install Loki (monolithic mode) and Grafana into `md-dev-cluster`.
- Configure Loki's S3 driver against `platform-logs`.
- Add a *second* Vector sink in both clusters' `vector.yaml`. Keep the
  AWS ES sink. Vector fans out to both. Cost during parallel run is
  small (Loki stays mostly empty until traffic flows).
- Validate in Grafana Explore: search for a known log line, verify
  `level`, `service`, `user`, `phone` filters work.

### Days 2–30 — Parallel run

- Vector writes to both ES and Loki every day.
- Spot-check daily: pick yesterday's incident-y looking log in Kibana,
  reproduce the same query in Grafana Explore. They should agree.
- Watch Loki's `loki_distributor_bytes_received_total` against AWS ES
  index growth — they should track within ~10%.

### Day 31 — Cutover

- Remove the `elasticsearch` sink from both `vector.yaml`s, leaving
  only `loki`.
- Stop the AWS Elasticsearch domain (do not delete yet — keep the
  snapshot for ~7 days as insurance).
- After a week of clean Loki-only operation, delete the AWS domain.

### Documentation

- Update `docs/INFRASTRUCTURE.md` ("Logging" section) in this repo to
  reflect Loki, query examples, retention, and the
  labels-vs-line-content shift.
- Add a one-page LogQL cheat-sheet to `docs/OPERATIONS.md` covering the
  five most common queries.

## Risks and gotchas (honest list)

- **Historical AWS ES data does NOT migrate.** Loki starts empty on
  cutover day. If anyone needs ES data from before, they query Kibana
  during the parallel window. Acceptable: logs are operational, not a
  regulatory archive (medical device regulatory data lives in Postgres).
- **LogQL is a learning curve** for anyone who only knows Kibana. Plan
  a 30-minute team walkthrough before cutover. Document the Kibana →
  LogQL translations for the queries we actually run.
- **Grafana becomes the de-facto UI.** No more Kibana. If Grafana's
  Explore UX feels worse for a particular workflow, rollback is
  cheap (re-add the AWS sink) but the AWS domain we just canceled
  will be cold for 7 days — plan accordingly.
- **Cross-cluster ingest from `pre` → `dev`** travels over public
  internet (TLS terminated at the dev cluster's NGINX). Same path
  Vector uses today to reach AWS ES. No new risk; rate-limit Vector's
  retry policy as a cheap safety belt.
- **Cardinality footguns** to flag in code review: `pod` and
  `pod_uid` are kubernetes-native labels Vector exports by default.
  Strip them before sending to Loki, otherwise pod restarts
  multiply stream count. Use `labels.namespace`/`labels.service`/
  `labels.env`/`labels.level` and nothing else as labels.
- **Loki single-replica means a Loki crash drops in-flight WAL** until
  the pod restarts. The 10 GiB PVC catches this on disk; the only true
  data loss window is the seconds between Vector's last flush and the
  crash. Acceptable for ops logs. If we wanted HA, we'd need 3
  replicas + a memcached cluster — pillar 04 considers this and
  rejects it for cost reasons.

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

- [ ] Loki + Grafana running in dev cluster, both fronted by ingress
- [ ] Vector in both clusters writes to Loki (and to AWS ES during the
      parallel window)
- [ ] At least 30 days of parallel-run data, spot-checked
- [ ] AWS Elasticsearch sink removed from `vector.yaml`
- [ ] AWS Elasticsearch domain stopped (then deleted ≥7 days later)
- [ ] `INFRASTRUCTURE.md` and `OPERATIONS.md` updated with Loki + LogQL
- [ ] Team walkthrough delivered, LogQL cheat-sheet linked
