# OPERATIONS — Daily ops, troubleshooting, runbooks

## Cluster context — first thing to check, every time

The single biggest operational risk is acting on the wrong cluster. Before any `kubectl`, `helm`, or `kustomize` command:

```bash
kubectl config current-context
# Expected:
#   do-fra1-md-dev-cluster   when working on dev-0
#   do-fra1-md-pre-cluster   when working on pre (= production)
```

Switch with:

```bash
kubectl config use-context do-fra1-md-dev-cluster
# or
kubectl config use-context do-fra1-md-pre-cluster
```

Tip: alias your shell prompt to show the current k8s context (`kube-ps1`, `starship k8s` module, etc.). Many wrong-cluster mistakes are caught by simply seeing the cluster in your prompt.

## Authenticating to a cluster

If you don't have a kubectl context yet:

```bash
# Using DigitalOcean CLI (preferred)
doctl auth init                     # one-time, asks for PAT
doctl kubernetes cluster kubeconfig save md-dev-cluster
doctl kubernetes cluster kubeconfig save md-pre-cluster

# Verify
kubectl get nodes
```

The `k8s/` repo also contains `md-dev-cluster-kubeconfig.yaml` — a snapshot of the dev kubeconfig. Tokens in it expire; prefer `doctl` for fresh credentials.

## Reading logs

### Single pod or deployment

```bash
# Tail latest logs
kubectl logs -f deployment/md-core --tail=200

# Previous container instance (after a crash)
kubectl logs deployment/md-core --previous

# All pods of a service together
kubectl logs -f -l app=md-core --max-log-requests=10

# Around a specific time
kubectl logs deployment/md-core --since=10m
```

### Centralized logs (Logtail)

All container stdout is shipped to Logtail by the `vector` DaemonSet. Logtail UI gives:

- Time-range search
- JSON field filters (Quarkus services emit JSON, fields like `level`, `traceId`, `loggerName`, `pharmacy_id`)
- Saved queries per service

### MQTT traffic

Not in Logtail. Connect a debug client to the broker:

```bash
mosquitto_sub -h 67.207.73.146 -p 1883 -t '#' -v
# Use IoT credentials from the env's ConfigMap
```

## Health checks

Each service exposes Quarkus `/q/health/ready`. Ingress also routes `/health/<svc>` to the same.

```bash
# Production
for svc in md-core md-auth md-resi-back md-resi-front; do
  printf '%-15s ' "$svc"
  curl -s -o /dev/null -w '%{http_code}\n' https://app.fagorhealthcare.com/health/$svc
done

# Or hit the json
curl -s https://app.fagorhealthcare.com/q/health | jq
```

`UP` overall — the service can serve. `DOWN` — drill into `checks[]` for which dependency failed (Postgres, MQTT, Twilio).

## Pod hygiene

```bash
# Status of everything in default ns
kubectl get pods,deployments,statefulsets,cronjobs,ingress

# Recent events (most useful for diagnosing failed schedules, OOMKills)
kubectl get events --sort-by='.lastTimestamp' | tail -30

# Resource consumption
kubectl top pods                           # needs metrics-server
kubectl describe pod <name> | grep -A5 -E 'Limits|Requests|Last State'
```

## Restarting a service

```bash
# Rolling restart (zero downtime)
kubectl rollout restart deployment/md-core

# Force-recreate a single misbehaving pod
kubectl delete pod -l app=md-core --field-selector=status.phase!=Running
```

## Database operations

Connect to the managed Postgres:

```bash
# From the user's machine (requires DO firewall rule for source IP)
psql "postgresql://user:pass@md-pre-postgresql-do-user-2821405-0.b.db.ondigitalocean.com:25061/pre-pool?sslmode=require"
```

Common queries:

```sql
-- Recent activity
select count(*), date_trunc('hour', created_at) bucket
from activity_log_entry
where created_at > now() - interval '24h'
group by bucket order by bucket;

-- Flyway migration state per service
select * from flyway_schema_history order by installed_rank desc limit 10;
select * from flyway_resi_schema_history order by installed_rank desc limit 10;

-- Quartz currently-firing triggers (md-core)
select trigger_name, next_fire_time, prev_fire_time, trigger_state
from qrtz_triggers order by next_fire_time;
```

Backups: see the `md-backup` CronJob status:

```bash
kubectl get cronjob md-backup
kubectl get jobs -l app=md-backup --sort-by='.status.startTime' | tail -5
kubectl logs job/<latest-job-name>
```

## Certificate management

### Inspect what's currently served

```bash
# Live endpoint
echo | openssl s_client -connect app.fagorhealthcare.com:443 -servername app.fagorhealthcare.com 2>/dev/null \
  | openssl x509 -noout -dates -issuer -subject

# Cluster-side
kubectl get secret fagor-do-tls -o json | jq -r '.data."tls.crt"' | base64 -d \
  | openssl x509 -noout -dates -issuer -subject

# All certificate resources (cert-manager managed)
kubectl get certificate
kubectl describe certificate fagor-do-tls
```

### Renewing the Cinfa wildcard (manual, ~once a year)

Full step-by-step in `k8s/CLAUDE.md`. Summary:

1. Receive new `wildcard.cinfa.com.YYYY.{crt,key}` + `DigiCertCA.YYYY.crt` from DigiCert
2. `kubectl config current-context` → `do-fra1-md-pre-cluster`
3. Archive in `k8s/cinfassl/YYYY/`
4. `cat wildcard...crt DigiCertCA...crt > fullchain.crt`
5. Backup current secret, then `kubectl delete secret cinfa-adhoc-cert` and recreate via `kubectl create secret tls`
6. `kubectl rollout restart deployment -n ingress-nginx ingress-nginx-controller`
7. Verify with `openssl s_client -connect medicaldispenser-sw.cinfa.com:443`

**Critical**: do not let cert-manager attempt to manage this cert. The Ingress entry that uses `cinfa-adhoc-cert` must NOT have a `cert-manager.io/issuer` annotation.

### Renewing JWT keys

Per-environment 2048-bit RSA keys. `k8s/SECURITY.txt` has the openssl commands; the secret name is `ssh-key-secret`. If you rotate JWT keys in pre, you invalidate every issued token, forcing all users to re-auth — coordinate with product.

## Secrets inventory

| Secret name | Purpose | Rotation |
|---|---|---|
| `ssh-key-secret` | RSA keypair for JWT signing | manual, rare |
| `fagor-do-tls` | Let's Encrypt TLS for *.fagorhealthcare.com | auto via cert-manager |
| `fagor-nodered-tls` | LE TLS for nodered.* | auto via cert-manager |
| `cinfa-adhoc-cert` | DigiCert wildcard *.cinfa.com | manual yearly |
| `s3-backup-key` | AWS keys for backup CronJob | manual, rare |
| `md-dockerhub-regcred` | DockerHub pull secret | manual when CI creds rotate |
| `digitalocean-dns` | DNS-01 token for cert-manager (pre only) | manual |

## NodeRed / n8n hygiene

After the March 2026 cryptominer incident (see [INCIDENTS.md](INCIDENTS.md)):

- The NodeRed editor must NOT be exposed without authentication. Verify the Ingress for `nodered.*` requires basic auth or is restricted to allowlist IPs.
- Periodically inspect NodeRed flows: `kubectl exec -it md-node-red-0 -- cat /data/flows.json` — look for unexpected `inject` nodes with `once: true` and any `exec` nodes invoking shell commands.
- The infected backup `nodered-flows-infected.json` is preserved in `k8s/data/` as forensic evidence.

## Common failure modes

### "Pod CrashLoopBackOff" on a Quarkus service

1. `kubectl logs <pod> --previous` — usually a Flyway migration error or DB connectivity
2. Check Postgres reachability from inside the cluster:
   ```bash
   kubectl run -it --rm pg-test --image=postgres:14 --restart=Never -- \
     psql "postgresql://...:25061/dev-pool?sslmode=require" -c 'select 1'
   ```
3. If Flyway is the culprit, decide:
   - If migration is reversible → revert image and write a new migration that fixes the schema
   - If not → connect to the DB, manually fix the `flyway_schema_history` row, then redeploy

### "Ingress 502" on a route

1. Backing service has zero Ready pods? `kubectl get endpoints <svc>` returns empty?
2. Backing pod's `/q/health` failing internally? Check liveness/readiness probe failures in pod events.
3. NGINX timeout? Default `proxy-read-timeout: 300` — large/slow operations can exceed this; bump per-Ingress annotation.

### "Image pull error"

1. Image actually exists on DockerHub? `docker buildx imagetools inspect gailen/<svc>:<tag>`
2. `md-dockerhub-regcred` valid? `kubectl get secret md-dockerhub-regcred -o yaml` and decode auth field — ensure the username `gailen` and a non-empty password.

### "MQTT messages not reaching device"

1. Broker reachable? `nc -zv 67.207.73.146 1883`
2. md-core's MQTT client connected? Logs should show SmallRye reactive messaging connection events
3. NodeRed flow forwarding correctly? Check NodeRed logs and editor

## On-call quick reference

```bash
# Set context to production
kubectl config use-context do-fra1-md-pre-cluster

# Glance
kubectl get pods,ingress
kubectl get events --sort-by='.lastTimestamp' | tail -20

# Service health bingo
for h in app.fagorhealthcare.com fmd.fagorhealthcare.com; do
  for s in md-core md-auth md-resi-back md-resi-front; do
    printf '%s/%s : ' $h $s
    curl -s -o /dev/null -w '%{http_code}\n' https://$h/health/$s
  done
done

# Last 20 deploys (per service)
git -C k8s log --oneline -20

# Recent commits across all repos at once
for r in md-core md-pwa md-auth md-resi-back md-resi-front; do
  echo "=== $r ==="
  git -C $r log --oneline -5
done

# Tail prod logs from md-core
kubectl logs -f -l app=md-core --tail=100
```
