# Pillar 06 — Platform Tier (Dedicated Droplet)

Status: **proposed** | Estimated savings: **−€48/mo** (replaces AWS ES) | Setup cost: **~€25/mo** (droplet + snapshot + Spaces) | Effort: **~3 days** | Risk: **low** | Depends on: **none** (but is a prerequisite for 02 and 03)

A dedicated **single Debian droplet** running `docker compose` hosts the
shared platform services (Caddy, Zot, Loki — and any future cross-cluster
infra) on its own subdomain `*.platform.fmd.fagorhealthcare.com`. The two
DOKS app clusters (`md-dev-cluster`, `md-pre-cluster`) stay untouched.

This is the central pillar of the new architecture: pillars 02 (registry)
and 03 (logging) both *land here*, not in either app cluster.

## Why a droplet, not a third cluster, not in the dev cluster

Three options were considered:

1. **Platform services in the dev cluster** (the original Scenario B from
   pillar 04, now superseded). Rejected because:
   - **Chicken-and-egg**: a registry whose own image is pulled from itself
     is fragile during cluster bootstrap and incident recovery.
   - **Blast radius**: a control-plane incident in dev kills both apps and
     observability. A standalone tier breaks that coupling.
   - **Audit narrative**: "platform services run on a separate, dedicated
     host" is a one-line answer in healthcare procurement reviews.
2. **A third DOKS cluster ("platform cluster")**. Rejected on cost — a
   single-node DOKS cluster still pays for at least one node + LB + control
   plane overhead, totaling ~$36/mo for what is fundamentally a 3-service
   workload that doesn't scale or reschedule.
3. **A single Debian droplet running `docker compose`** (this pillar). The
   3–4 services here are static, low-resource, and rarely updated. Kubernetes
   adds operational overhead (control plane, kubelet, networking, RBAC,
   manifests) for zero benefit at this scale. `docker compose up -d` and a
   weekly snapshot is the right tool.

## Architecture

```
                          GitHub Actions / Operators
                                       │
                                       │ docker push, docker pull, vector push
                                       ▼
              ┌──────────────────────────────────────────────────┐
              │  *.platform.fmd.fagorhealthcare.com  (Caddy → ACME)  │
              └──────────────┬─────────────────┬─────────────────┘
                             │                 │
                  registry.platform     logs.platform
                             │                 │
              ╔══════════════▼═════════════════▼══════════════════╗
              ║  Debian droplet (s-2vcpu-4gb, fra1, reserved IP)  ║
              ║                                                   ║
              ║   ┌───────────┐  ┌─────────┐  ┌──────────┐        ║
              ║   │  caddy    │  │  zot    │  │  loki    │        ║
              ║   │  :80,:443 │  │  :5000  │  │  :3100   │        ║
              ║   └─────┬─────┘  └────┬────┘  └─────┬────┘        ║
              ║         │             │             │             ║
              ║   docker network "platform" (bridge, internal)    ║
              ╚════════════════════════╪═════════════╪════════════╝
                                       │             │
                                       ▼             ▼
                       ┌────────────────────┐  ┌─────────────────┐
                       │ Spaces:            │  │ Spaces:         │
                       │ platform-registry  │  │ platform-logs   │
                       │ (fra1)             │  │ (fra1)          │
                       └─────────┬──────────┘  └────────┬────────┘
                                 │                     │
                                 │  rclone sync (nightly via md-backup CronJob)
                                 ▼                     ▼
                       ┌──────────────────────────────────────────┐
                       │  AWS S3 (existing md-backup bucket)      │
                       │   /registry/  Standard → IA@30d → Glacier@180d │
                       │   /logs/      Standard → IA@30d → Glacier@180d │
                       └──────────────────────────────────────────┘

           md-dev-cluster ──pull/push──┐                       ┌──vector push── md-dev-cluster
           md-pre-cluster ──pull/push──┘ ──► registry  logs ◄──┘──vector push── md-pre-cluster
                                            (HTTPS, public, fra1↔fra1 ≪1 ms)
```

Both clusters reach the platform tier as ordinary HTTPS clients — same
pattern Vector uses today to reach AWS ES.

## `docker-compose.yml` skeleton

Copy-paste ready. Pin versions before deploying; placeholders below are
indicative and must be replaced with current stable releases at install
time (verify against the upstream release notes; see "Open questions"
below).

```yaml
# /opt/platform/docker-compose.yml
networks:
  platform:
    driver: bridge

volumes:
  caddy_data:        # ACME state, certs
  caddy_config:
  loki_wal:          # WAL + boltdb-shipper local cache (10 GiB)

services:
  caddy:
    image: caddy:2.8-alpine     # pin to latest 2.x stable at install time
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks: [platform]

  zot:
    image: ghcr.io/project-zot/zot-linux-amd64:v2.1.2   # pin; see open questions
    restart: unless-stopped
    expose:
      - "5000"
    volumes:
      - ./zot-config.json:/etc/zot/config.json:ro
    networks: [platform]
    # NOTE: no ports: — only Caddy reaches it.

  loki:
    image: grafana/loki:3.3.0    # pin; see open questions
    restart: unless-stopped
    expose:
      - "3100"
    command: -config.file=/etc/loki/loki-config.yaml
    volumes:
      - ./loki-config.yaml:/etc/loki/loki-config.yaml:ro
      - loki_wal:/loki
    networks: [platform]
```

## `Caddyfile` skeleton

```Caddyfile
# /opt/platform/Caddyfile
{
    email ops@fagorhealthcare.com
    # Caddy auto-provisions Let's Encrypt certs on first request.
}

registry.platform.fmd.fagorhealthcare.com {
    reverse_proxy zot:5000
    # Optional: rate-limit anonymous reads at the edge
}

logs.platform.fmd.fagorhealthcare.com {
    reverse_proxy loki:3100
    # Loki's HTTP API expects POSTs from Vector at /loki/api/v1/push;
    # Caddy passes everything through unmodified.
}
```

## `zot-config.json` skeleton

```json
{
  "distSpecVersion": "1.1.0",
  "storage": {
    "rootDirectory": "/var/lib/registry",
    "remoteCache": false,
    "storageDriver": {
      "name": "s3",
      "rootdirectory": "/registry",
      "region": "fra1",
      "regionendpoint": "https://fra1.digitaloceanspaces.com",
      "bucket": "platform-registry",
      "secure": true,
      "skipverify": false
    }
  },
  "http": {
    "address": "0.0.0.0",
    "port": "5000",
    "auth": {
      "htpasswd": { "path": "/etc/zot/htpasswd" },
      "failDelay": 5
    },
    "accessControl": {
      "repositories": {
        "**": {
          "anonymousPolicy": ["read"],
          "policies": [
            { "users": ["ci"], "actions": ["read","create","update","delete"] }
          ]
        }
      }
    }
  },
  "extensions": {
    "search": { "cve": { "updateInterval": "24h" } },
    "ui": { "enable": true },
    "metrics": { "enable": true }
  }
}
```

Anonymous read = unauthenticated cluster pulls (read-only). The `ci`
user (htpasswd) is the only writer. Spaces credentials come from
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` env vars passed into the
container.

## `loki-config.yaml` skeleton

```yaml
# Monolithic mode, single replica
auth_enabled: false

server:
  http_listen_port: 3100

common:
  path_prefix: /loki
  storage:
    s3:
      endpoint: fra1.digitaloceanspaces.com
      bucketnames: platform-logs
      region: fra1
      s3forcepathstyle: false
      insecure: false
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2026-01-01
      store: tsdb
      object_store: s3
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  retention_period: 8760h     # 365 days
  reject_old_samples: true
  reject_old_samples_max_age: 168h

compactor:
  working_directory: /loki/compactor
  retention_enabled: true
  delete_request_store: s3
```

## Backup / DR plan

### Nightly Spaces → AWS S3 sync

Extend the existing `md-backup` CronJob with an `rclone` step. The AWS S3
bucket already exists (used today for Postgres + K8s descriptor backups).
Reuse it with prefixes:

```
s3://md-backup-aws/
    /postgres/...        (existing)
    /k8s-descriptors/... (existing)
    /registry/           (NEW — mirrors spaces:platform-registry)
    /logs/               (NEW — mirrors spaces:platform-logs)
```

AWS S3 lifecycle policy on the new prefixes:

| Age | Tier |
|---|---|
| 0–30 d | S3 Standard |
| 30–180 d | S3 Standard-IA |
| 180 d+ | Glacier (Deep Archive for `/registry/`, Flexible for `/logs/`) |

Sketch (~30 lines bash, runs in the existing `md-backup` Alpine image):

```sh
#!/bin/sh
set -eu
rclone sync \
    --config /etc/rclone/rclone.conf \
    spaces:platform-registry/ aws-ia:md-backup/registry/ \
    --transfers 8 --checkers 16

rclone sync \
    --config /etc/rclone/rclone.conf \
    spaces:platform-logs/ aws-ia:md-backup/logs/ \
    --transfers 8 --checkers 16
```

### If the droplet dies

The droplet is **stateless**. All durable state lives in Spaces (registry
blobs, log chunks) and AWS S3 (DR copy). The droplet only holds:

- Caddy ACME state (re-issued on first request, ~30 s)
- Loki's WAL (seconds-scale buffer; on-disk content lost = the in-flight
  log lines between last flush and crash)
- The compose file itself (in git, in this platform repo)

Recovery procedure:

1. `terraform apply` against the platform repo — provisions a fresh
   droplet (~3 min) attached to the same reserved IP. DNS does not
   change because the reserved IP did not change.
2. cloud-init clones the platform repo and `docker compose up -d`.
3. Caddy requests fresh certs via Let's Encrypt (~30 s).
4. Zot reads existing blobs from `platform-registry` Spaces.
5. Loki reads existing chunks from `platform-logs` Spaces.

End-to-end recovery: **~5 minutes**, no manual data restore needed.

## Honest gotchas

- **Single droplet = single point of failure** for new image pulls and
  for log pushes. Mitigations:
  - Vector has on-disk buffering (`buffer.type=disk`); if Loki is
    unreachable, logs queue locally on the cluster nodes for hours
    before drop. Configure `buffer.max_size_bytes=2GiB` per Vector
    pod.
  - Image pulls fail soft: existing pods keep running with their
    cached image; only new pod scheduling is blocked.
  - Caddy ACME state is regenerated on a fresh droplet within seconds
    on first request. Let's Encrypt rate limits (50 certs/week per
    domain) are nowhere near our usage.
- **Maintenance windows must be coordinated** across both clusters.
  Restarting the droplet during a release is a non-event for running
  pods but blocks new image pulls for the restart duration. Plan
  restarts off-hours.
- **You operate Debian.** Apt updates, `unattended-upgrades`,
  `fail2ban`, basic monitoring (UptimeRobot or DO monitoring on the
  reserved IP) are now your responsibility, not DOKS's.
- **Caddy ACME state lives ON the droplet.** Loss of the droplet =
  fresh certs from Let's Encrypt on the rebuilt droplet. We are well
  inside the rate limit, but a flapping droplet that comes up and dies
  repeatedly within an hour could hit it. Mitigation: don't do that;
  if the droplet is unstable, terraform-destroy and re-create cleanly.
- **VRL parse failures from the existing pipeline still need verifying
  post-cutover.** The 11 failed-medicaldispenser-* indices in AWS ES
  (Dec 2025–May 2026) suggest intermittent ingest failures the AWS
  side silently dropped. Loki+Vector will mitigate the *transport*
  side (Vector retries with disk buffer), but if the underlying parse
  errors recur, Loki will see the same dropped-event count. Track
  `vector_component_errors_total` after cutover.
- **No HA for the platform tier itself.** This is intentional at our
  scale. If we ever justify HA: Loki + Caddy + Zot all tolerate
  multiple replicas behind a load balancer, but we'd need shared
  state for Caddy's ACME (e.g. a Spaces-backed `caddy-storage-s3`
  module) and a real LB. Out of scope.

## Cost detail

Monthly, EUR-equivalent at 1 USD ≈ €0.92:

| Item | USD | EUR |
|---|---|---|
| Droplet `s-2vcpu-4gb`, fra1 | $24 | ~€22 |
| Weekly snapshot of droplet (~50 GiB) | $3 | ~€2.75 |
| Spaces `platform-registry` + `platform-logs` (one $5 base unit covers both) | $5 | ~€4.60 |
| AWS S3 IA backup (~5 GiB combined) | ~$1 | ~€1 |
| Reserved IP (free while attached to a running droplet) | $0 | €0 |
| **Platform tier total** | **~$33** | **~€30** |

Comparison vs the AWS Elasticsearch service this replaces:

| Item | Monthly | Notes |
|---|---|---|
| AWS ES (today) | ~€70 / ~$77 | 49 GiB allocated, 218 MiB used (0.4% util) — grossly over-provisioned but the tier doesn't go smaller |
| Platform tier (proposed) | ~€30 / ~$33 | Includes registry + scanning + 365 d retention |
| **Net** | **−€40 to −€48 / ~−$44** | Plus: vuln scanning, no DockerHub paid plan, controlled retention |

The AWS ES line is sized for the smallest reasonable production-shape
domain; we cannot scale it down to match our actual 218 MiB footprint
without dropping below operational viability. That over-provisioning
is the financial backdrop for this migration: even at 100× current log
volume, the platform tier stays inside the same $33/mo envelope.

## Volume context (drives the retention decision)

Measured against AWS ES today:

- **Total cluster usage**: 218 MiB across all indices.
- **Daily raw input**: ~25 MiB/day.
- **Daily Snappy-compressed input** (Loki's chunk format): ~5 MiB/day.
- **365-day projection**: 365 × 5 MiB ≈ **1.8 GiB/year**.

DO Spaces `$5/mo` base tier includes 250 GiB. We use 1.8 GiB in year 1,
~9 GiB after 5 years. **Retention is essentially free** at this volume.
Even 10× growth (e.g. WhatsApp DEBUG enabled enterprise-wide) keeps us
inside the included quota.

This is why the retention decision is **365 days** by default — and could
be 5 years for the same monthly bill if a regulatory question ever turns
up. See pillar 03 for the operational query/UX implications.

## Terraform module sketch

All infra-as-code for the platform tier lives in `terraform/` at the
root of the platform repo. State backend: DO Spaces, separate bucket
(`platform-tfstate`), versioned.

```
terraform/
  main.tf          # droplet, reserved IP, cloud firewall
  dns.tf           # platform.fmd.fagorhealthcare.com zone + records
  spaces.tf        # platform-registry, platform-logs (versioning + lifecycle)
  cloud-init.yml   # apt install docker, clone repo, docker compose up -d
  variables.tf     # ssh_keys, region, sizes
  outputs.tf       # reserved_ip, dns FQDNs
  backend.tf       # spaces://platform-tfstate/terraform.tfstate
```

What gets provisioned:

| Resource | Detail |
|---|---|
| `digitalocean_droplet.platform` | `s-2vcpu-4gb`, image `debian-12-x64`, region `fra1`, IPv6 enabled, monitoring agent enabled, `user_data = file(cloud-init.yml)` |
| `digitalocean_reserved_ip.platform` | Anchors a stable IP across droplet rebuilds |
| `digitalocean_reserved_ip_assignment` | Binds it to the droplet |
| `digitalocean_firewall.platform` | Inbound: 22/tcp from operator IPs only; 80,443/tcp from `0.0.0.0/0`; 22 outbound to anywhere; standard ICMP |
| `digitalocean_domain.platform` | `platform.fmd.fagorhealthcare.com` (NEW zone — needs DNS delegation set up in the Fagor parent zone first) |
| `digitalocean_record.registry` | A → reserved IP |
| `digitalocean_record.logs` | A → reserved IP |
| `digitalocean_spaces_bucket.registry` | `platform-registry`, fra1, versioning on, ACL private |
| `digitalocean_spaces_bucket.logs` | `platform-logs`, fra1, versioning on, ACL private |

`cloud-init.yml` outline:

```yaml
#cloud-config
package_update: true
packages: [docker.io, docker-compose-plugin, git, fail2ban, unattended-upgrades]
write_files:
  - path: /etc/systemd/system/platform.service
    content: |
      [Unit]
      Description=Platform docker-compose stack
      After=docker.service
      [Service]
      Type=oneshot
      RemainAfterExit=yes
      WorkingDirectory=/opt/platform
      ExecStart=/usr/bin/docker compose up -d
      ExecStop=/usr/bin/docker compose down
      [Install]
      WantedBy=multi-user.target
runcmd:
  - git clone https://github.com/FagorHealthcare/platform.git /opt/platform-repo
  - cp -r /opt/platform-repo/platform/* /opt/platform/
  - systemctl enable --now platform.service
```

## DNS setup — one-time

The zone `platform.fmd.fagorhealthcare.com` does **not exist yet**. Before
the first `terraform apply`:

1. In the parent registrar / DNS zone for `fagorhealthcare.com`, add NS
   records for `platform` delegating to DigitalOcean's nameservers
   (`ns1.digitalocean.com` etc.).
2. `terraform apply` then owns the zone end-to-end.

This isolates the platform DNS from the application DNS — accidental
edits to app DNS do not affect platform availability and vice versa.

## Effort breakdown (~3 days)

### Day 1 — Provisioning

- Write Terraform modules in `terraform/`.
- Set up DNS delegation for `platform.fmd.fagorhealthcare.com`.
- `terraform init` (Spaces backend), `terraform plan`, `terraform apply`.
- Verify droplet reachable via reserved IP, DNS resolves, Caddy serves
  a default placeholder over HTTPS.

### Day 2 — Zot

- Author `zot-config.json`, generate `htpasswd` for the `ci` user, store
  the bcrypt hash in a sealed secret committed to the repo.
- Bring up Zot in the compose stack, push a smoke image with `docker
  push registry.platform.fmd.fagorhealthcare.com/test:latest`.
- Verify Trivy CVE database update fires.
- Document Spaces credentials in the platform repo's secrets section
  (sealed or via 1Password reference, never in plaintext).

### Day 3 — Loki

- Author `loki-config.yaml` with the S3 backend pointing at
  `platform-logs`.
- Bring up Loki in the compose stack, verify `/ready` and `/metrics`.
- Point one Vector instance (start with dev cluster's Vector) at
  `https://logs.platform.fmd.fagorhealthcare.com` as a *second* sink (keep
  AWS ES alongside per pillar 03's parallel-run requirement).
- Run a representative LogQL query in `logcli` or curl to confirm a
  log line lands and is searchable.
- Extend `md-backup` CronJob with the `rclone sync` step; let it run
  once and verify objects appear under the `/registry/` and `/logs/`
  prefixes in the AWS S3 bucket.

## Done when

- [ ] `terraform apply` runs cleanly from a fresh checkout
- [ ] DNS resolves for `*.platform.fmd.fagorhealthcare.com`
- [ ] Caddy serves valid Let's Encrypt certs for both subdomains
- [ ] Zot push/pull works from a laptop and from inside both DOKS clusters
- [ ] Trivy CVE results visible via `/v2/_zot/ext/search?…`
- [ ] Loki ingests from at least one Vector instance and is queryable
- [ ] Spaces buckets contain registry blobs and Loki chunks
- [ ] `md-backup` CronJob has mirrored both Spaces buckets to AWS S3 at
      least once, with the lifecycle policies applied
- [ ] DR drill performed: `terraform destroy` + `terraform apply` recovers
      a working droplet within 10 minutes

## Cross-references

- Pillar 02 (registry) lands here — see [02-registry.md](02-registry.md)
- Pillar 03 (logging) lands here — see [03-logging.md](03-logging.md)
- Topology rationale superseded by this pillar — see [04-cluster-topology.md](04-cluster-topology.md)
- Earlier "platform in dev cluster" rejection added — see [05-not-doing.md](05-not-doing.md)

## Open questions / TBD before implementation

- Exact Zot version pin: `v2.1.2` is illustrative. Verify the latest
  stable on `https://github.com/project-zot/zot/releases` at install
  time and pin precisely (avoid `latest`).
- Exact Loki version pin: `3.3.0` is illustrative. The `3.x` line has
  schema-config implications (`v13` vs `v12`); verify the chosen tag
  ships with `tsdb` + `schema v13` defaults.
- AWS S3 prefix layout: this doc uses `/registry/` and `/logs/`. If the
  existing `md-backup` bucket has a different prefix convention (check
  `md-backup` repo before applying lifecycle rules), align with it.
- Whether the htpasswd `ci` user should be replaced by GitHub OIDC
  (Zot supports it) for keyless CI auth — defer until after first
  cutover to keep the initial setup boring.
