# Platform stack — `docker compose` deliverable

The TLS edge + image registry + log aggregator that the rest of Fagor
Healthcare's clusters call into. Runs on the dedicated Debian droplet
provisioned by the [`../terraform/`](../terraform/) module.

```
*.platform.fmd.fagorhealthcare.com (LE TLS at Caddy)
        │
        ├── registry.platform.… ──► zot   ──► DO Spaces (platform-registry)
        └── logs.platform.…     ──► loki  ──► DO Spaces (platform-logs)
```

Cross-references:

- [`../docs/migration/06-platform-tier.md`](../docs/migration/06-platform-tier.md) — canonical spec
- [`../docs/migration/02-registry.md`](../docs/migration/02-registry.md) — Zot details
- [`../docs/migration/03-logging.md`](../docs/migration/03-logging.md) — Loki details
- [`../terraform/README.md`](../terraform/README.md) — the substrate this stack runs on

## Pinned versions

All images are pinned to a real semver tag — never `latest`.

| Service | Image | Notes |
|---|---|---|
| Caddy | `caddy:2.10-alpine` | Latest 2.x stable line as of late 2025 / early 2026 |
| Zot | `ghcr.io/project-zot/zot-linux-amd64:v2.1.5` | Verify [latest release](https://github.com/project-zot/zot/releases) before bumping. Schema-affecting upgrades require care. |
| Loki | `grafana/loki:3.5.5` | 3.x line ships `tsdb` + `schema v13` defaults. Bump to current 3.x if newer is out. |

Bump policy: refresh these pins on every minor release, after reading
upstream release notes for breaking changes. **Never** float a Zot or
Loki image to `latest` — silent schema upgrades are how registries and
log stores get bricked.

## What lives where

| Service | Config file | Volume | Public hostname | Internal port |
|---|---|---|---|---|
| caddy | `caddy/Caddyfile` | `caddy_data`, `caddy_config` | n/a (publishes 80/443 on host) | — |
| zot | `zot/config.json.tmpl` (rendered → `zot_rendered`) + `zot/htpasswd` | `zot_rendered` (rendered config only — blobs live in DO Spaces) | `registry.platform.fmd.fagorhealthcare.com` | 5000 |
| loki | `loki/loki-config.yaml` | `loki_wal` (WAL + tsdb local cache — chunks live in DO Spaces) | `logs.platform.fmd.fagorhealthcare.com` | 3100 |

Caddy is the only service that publishes to the host network. Zot and
Loki bind exclusively to the `platform` bridge network and are NOT
reachable from outside the droplet.

## Templated configs

### Zot — init-container `envsubst` rendering

Zot does **not** natively expand `${VAR}` references in its config
file. We work around this with a small init container
(`zot-config-render`):

1. Reads `zot/config.json.tmpl` (committed to git, contains `${SPACES_*}`
   placeholders).
2. Runs `envsubst` (from `gettext`) over it, with the env from `.env`.
3. Writes the rendered JSON into the `zot_rendered` named volume.
4. Zot then mounts `zot_rendered:/etc/zot:ro` and reads its config.

Trade-off: an extra container in the compose graph. The alternative —
baking a wrapper into a custom Zot image — would mean rebuilding and
re-pinning a derived image on every Zot upgrade. The init-container
path keeps us on the upstream-published image with zero rebuild step;
the cost is a one-shot container that runs to completion at
`docker compose up`.

### Loki — built-in `-config.expand-env`

Loki has native env-var substitution: launching with
`-config.expand-env=true` makes it expand `${VAR}` references in the
config file at startup. No init container needed. We pass the flag in
`docker-compose.yml`.

## First-time setup on the droplet

The cloud-init in `../terraform/cloud-init.yaml.tftpl` clones this repo
to `/opt/platform-repo` and links `/opt/platform/stack` →
`/opt/platform-repo/platform`. After `terraform apply` finishes:

1. SSH into the droplet (substitute the reserved IP from
   `terraform output -raw droplet_ipv4`):

   ```sh
   ssh root@<reserved_ip>
   ```

2. The cloud-init has already cloned the repo. Verify:

   ```sh
   ls -l /opt/platform/stack
   ```

3. Edit the operator-supplied `.env`. Cloud-init has already pre-seeded
   it at `/opt/platform/.env` (with `LETSENCRYPT_EMAIL` filled in from
   `terraform.tfvars`) and symlinked it into the stack directory:

   ```sh
   cd /opt/platform/stack
   $EDITOR .env             # this is the symlink → /opt/platform/.env
   ```

   Fill in the four DO Spaces values (`SPACES_*` and `LOKI_S3_*`).
   `.env.example` is included in this repo as the canonical reference
   for what variables exist; on the droplet you edit the pre-seeded
   `.env` directly.

4. Generate Zot's htpasswd file (writers + read-only consumer).
   `htpasswd` is preinstalled on the droplet by cloud-init via the
   `apache2-utils` package:

   ```sh
   htpasswd -Bc zot/htpasswd ci        # CI user (push + pull); prompts for password
   htpasswd -B  zot/htpasswd cluster   # cluster user (pull only); prompts for password
   chmod 0640 zot/htpasswd
   ```

   The `htpasswd` file is **not** committed to git — it stays
   droplet-local. Keep the cleartext passwords in a password manager
   (1Password / Bitwarden / etc.).

5. Bring the stack up:

   ```sh
   docker compose up -d
   docker compose logs -f
   ```

6. From your laptop, verify TLS + endpoints:

   ```sh
   curl -I https://registry.platform.fmd.fagorhealthcare.com/v2/
   # Expect: HTTP/2 401  (Zot demands auth — that's success)

   curl -I https://logs.platform.fmd.fagorhealthcare.com/ready
   # Expect: HTTP/2 200
   ```

   First-time TLS handshake takes ~30 seconds while Caddy completes the
   ACME HTTP-01 challenge.

## Updating the stack

```sh
cd /opt/platform/stack
git -C /opt/platform-repo pull
docker compose pull
docker compose up -d
```

Caddy's ACME state and Loki's WAL persist across restarts via named
volumes — no certs are reissued, no in-flight log lines lost.

## Day-2 ops

| Task | Command |
|---|---|
| Tail logs | `docker compose logs -f --tail 100 <service>` |
| Stack health | `docker compose ps` |
| Disk usage | `docker system df` then `du -sh /var/lib/docker/volumes/*` |
| Restart one service | `docker compose restart <service>` |
| View Caddy ACME state | `docker compose exec caddy ls -la /data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/` |
| Check Zot CVE DB freshness | `docker compose logs zot \| grep -i trivy` |
| Loki readiness | `docker compose exec loki wget -qO- http://localhost:3100/ready` |

Backups: this stack is **stateless** beyond Caddy's ACME state and
Loki's WAL. The durable data lives in DO Spaces (`platform-registry`,
`platform-logs`) and is mirrored to AWS S3 by the
[`md-backup`](https://github.com/FagorHealthcare/md-backup) CronJob —
configured separately, not here.

## Troubleshooting

| Symptom | First thing to check |
|---|---|
| Cert won't issue | Port 80 open in firewall? DNS resolves to the droplet's reserved IP? |
| Zot rejects pushes | `zot/htpasswd` exists and matches the user you're logging in as |
| Zot fails to start | `docker compose logs zot-config-render` — did `envsubst` run? Are the `SPACES_*` env vars set in `.env`? |
| Loki rejects writes | Check Vector's basic-auth header — auth is enforced at Caddy, not Loki |
| Loki 5xx on writes | `docker compose logs loki` — usually Spaces credentials wrong or bucket name typo'd |
| Spaces 403 | `SPACES_ACCESS_KEY` lacks scope on the bucket; regenerate with full-bucket access |

## Out of scope for v1

Tracked in [`../docs/migration/06-platform-tier.md`](../docs/migration/06-platform-tier.md#honest-gotchas):

- **Per-bucket scoped Spaces keys.** Today the same key pair drives
  both Zot and Loki. Least-privilege would split: registry-only key
  for Zot, logs-only key for Loki. Not blocking v1; tighten later.
- **Grafana on the droplet.** v1 uses Grafana Cloud's free tier as the
  query frontend. Add a `grafana` service + Caddy route here only if
  the free tier becomes insufficient.
- **HA Loki.** Single-replica monolithic mode is correct at our
  volume. HA would require a real LB, shared ring KV, and rethinking
  the Caddy ACME story.
- **Zot OIDC / GitHub Actions OIDC auth.** Replaces htpasswd `ci` user
  with keyless CI. Defer until after migration cutover.
- **DNS-01 ACME challenge.** Would let us close ports 80/443 to the
  internet and only expose 443. Today's HTTP-01 is fine; revisit if
  the firewall posture tightens.
