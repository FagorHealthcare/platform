# INCIDENTS — Playbook & history

## On-call playbook

### 1. Identify scope

```bash
kubectl config use-context do-fra1-md-pre-cluster
kubectl get pods,deployments,ingress
kubectl get events --sort-by='.lastTimestamp' | tail -50
```

Customer impact?
- Public hostnames responding? `curl -I https://app.fagorhealthcare.com/`
- Login flow? Hit `/auth` from a browser
- Treatment data loading? Smoke-test md-pwa with a known patient

### 2. Stop further damage

If a bad deploy is suspected:

```bash
kubectl rollout undo deployment/<service>
```

If a security event is suspected:

```bash
# Scale to zero (cuts off external traffic to the affected service)
kubectl scale deployment/<service> --replicas=0

# Or for a stateful pod whose state may be compromised
kubectl scale statefulset/<service> --replicas=0
```

For NodeRed compromise specifically: scale to 0, detach the PVC for forensics (move the volume claim to a debug pod first), then clean before scaling back up.

### 3. Communicate

- Slack `#circupack` — same channel CI posts to
- If customer-visible: notify the Cinfa contact (escalation path TBD per contract)

### 4. Diagnose

- Logtail: filter the affected service in the time window
- `kubectl describe pod <name>` for OOMKilled or probe failures
- `kubectl exec` into a pod for direct inspection

### 5. Resolve & verify

- Apply fix (revert image, patch ConfigMap, etc.)
- Verify health: `/q/health` UP, no new errors in Logtail
- Re-tag in DockerHub if you reverted (otherwise `prod` tag becomes a lie)
- Post mortem within 5 working days for any customer-visible incident

## Past incidents

### 2026-05-08 — 504s en `/v4/v5/actualizacion` (Google Sheets 503 sobre NOTICIAS)

**Resumen**: 105 timeouts en `POST /v{4,5}/actualizacion` (clientes Delphi/Indy de farmacias) durante 40 min (13:13–13:52 UTC). Causa: Google Sheets API devolvió `503 service is currently unavailable` sobre el documento `NOTICIAS` (`1FX6Q5RORHiKEIuQR4QToN0yeK-LRH8TMultXwQgGJeg`) durante 27 min. NOTICIAS está en serie en el flow de NodeRed para v4/v5 (no para v3, que sobrevivió). El contrib `node-red-contrib-google-sheets@1.1.2` no falla rápido; reintenta hasta que nginx corta a 60 s.

**Detección**: queries.md #03/#04 sobre Loki revelaron el patrón de `request_time ≈ 60.0 s` exclusivo en /v4/v5. Smoking gun en `kubectl logs md-node-red-0` — 13 errores `[GSheet:NOTICIAS 1] The API returned an error: Error: The service is currently unavailable.` entre 15:22 y 15:49 Madrid.

**Resolución**: ninguna acción nuestra. Google se recuperó sólo a las 13:49 UTC (o alguien tocó la hoja — no verificable sin abrir el version history del propio sheet).

**Análisis completo**: [`docs/loki/queries.md` — sección "Investigación 2026-05-08 — Hallazgo A"](loki/queries.md).

**Acciones pendientes derivadas**:
- Cachear NOTICIAS en NodeRed con fail-open (mayor rentabilidad)
- Añadir `node-red` a `kubernetes_filter_1` de Vector (sin esto, futuros eventos similares se pierden)
- Investigar el patrón diario de 503 sobre `Hoja Eventos SHC` a las 04:03 UTC (aparece TODOS los días en los logs históricos del pod)

### 2026-03-23 — Cryptominer in NodeRed (dev cluster)

**Summary**: A cryptominer (xmrig) was injected into NodeRed flows on the dev cluster. The attacker exploited an unauthenticated NodeRed editor exposed via Ingress. Container was compromised; no host or other cluster nodes were touched. Detected by repeated OOMKill events on node `5w3ni`.

**Source of truth**: [`k8s/docs/incident-report-2026-03-23-cryptominer.md`](../k8s/docs/incident-report-2026-03-23-cryptominer.md) (full timeline, forensic analysis, IoC list)

**Forensic artifact**: [`k8s/data/nodered-flows-infected.json`](../k8s/data/nodered-flows-infected.json) — the captured malicious `flows.json`. Preserved as evidence; do not delete or run.

**Persistence mechanism**: malicious `inject` nodes with `once: true` in `flows.json` (in the PVC) — every NodeRed restart re-downloaded and re-executed the miner. The miner binary was NOT in the host filesystem.

**Resolution**:
1. Scaled NodeRed to 0
2. Moved the PVC to a debug pod for analysis
3. Cleaned `flows.json` and `.flows.json.backup` (kept only legitimate flows)
4. Scaled NodeRed back to 1
5. Rebooted node `5w3ni` to clear lingering processes

**Lessons / open work items**:
- NodeRed editor MUST require authentication. Add basic auth or IP allowlist to the `nodered.*` Ingress.
- Apply the same principle to n8n.
- Consider a NetworkPolicy preventing pods in `default` namespace from making outbound HTTP connections to non-allowlisted destinations (would have blocked the miner download).
- Monitor for OOM events as a security signal, not just a capacity signal. Repeated OOMKill of the same process name across multiple time windows is highly suspicious.
- All in-cluster admin services (NodeRed, n8n, future Adminer/PgAdmin) should default to "not internet-facing".

## Recurring drills (suggested cadence)

| Drill | Frequency | Owner |
|---|---|---|
| Cinfa cert renewal practice on a non-prod copy | quarterly | infra |
| Backup restore test (S3 → fresh DB) | semi-annual | infra |
| Rollback simulation (deploy known-bad → undo) | quarterly | dev |
| JWT key rotation in dev | annually | security/dev |
| NodeRed/n8n flow audit | monthly | infra |
| Sentry/Logtail alert review | monthly | dev |
