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

### 2026-05-09 — Quartz "relation does not exist" tras el run fallido del cronjob de backup

**Surfaced by**: alerta `MdCoreErrorBurstPre` disparándose durante la noche del 8→9 mayo 2026 (~215 errores en 12 h, en bursts cortos por la tarde-noche más uno largo de 48 min a partir de las 05:00 UTC).

**Estado**: ✅ causa raíz identificada y fix aplicado en `pre` el 2026-05-09. Validado con un run manual de `md-backup` (job `md-backup-fix-validation`).

**Resumen (TL;DR)**:

`md-backup` (el CronJob diario que hace `pg_dump`) conectaba a Postgres a través del **PgBouncer** del cluster (`pre-pool`, puerto 25061, modo transaction). `pg_dump` setea como primera operación `SET search_path = pg_catalog;` (documentado, lo necesita para usar nombres totalmente cualificados internamente). En modo transaction, ese setting puede quedarse pegado en el backend Postgres del pool — **especialmente cuando el job es matado a SIGKILL** (en este caso, por `activeDeadlineSeconds=600` cuando el dump tardó >10 min). PgBouncer no ejecuta `server_reset_query` correctamente sobre cierres abruptos, y el siguiente cliente que recicla esa conexión backend hereda `search_path = pg_catalog`. md-core's Quartz emite consultas unqualified (`SELECT ... FROM qrtz_locks`) que sólo resuelven con `search_path` que incluya `public` → fallan con `relation does not exist`.

**Fix aplicado**: `md-backup` ahora conecta directo a Postgres (puerto 25060, BD `defaultdb`) en lugar de pasar por PgBouncer. `pg_dump` es de un solo proceso, ~10 min al día, no se beneficia de un pool, y al ser conexión dedicada cualquier estado session-scoped muere con el proceso sin contaminar a nadie. También se subió `activeDeadlineSeconds` de 600 a 1800 para que un dump lento no se vuelva a interrumpir.

**Reproducido en directo (2026-05-09 ~10:18 UTC)**:

```sql
-- desde un pod del cluster, conectado a pre-pool (PgBouncer transaction-mode, port 25061)
SET search_path = pg_catalog;
SELECT * FROM qrtz_scheduler_state LIMIT 1;
ERROR:  relation "qrtz_scheduler_state" does not exist
LINE 1: SELECT * FROM qrtz_scheduler_state LIMIT 1;
                      ^
```

Y al abrir una **conexión nueva inmediatamente después**, `SHOW search_path;` aún devolvía `pg_catalog` — el setting persistió en el backend y se filtró al siguiente cliente. Tras 8 conexiones cortas con `RESET search_path` el pool se limpió y volvió a `"$user", public`.

**Smoking gun temporal (2026-05-09)**:

```
03:00:00 UTC  md-backup CronJob arranca
03:10:00 UTC  activeDeadlineSeconds=600 dispara → SIGKILL al pod (pg_dump muere a la mitad)
05:00:52 UTC  primera "relation qrtz_scheduler_state does not exist" en md-core
05:48:25 UTC  última (la conexión envenenada cicla por idle timeout)
```

Solo este día apareció el burst — porque solo este día el dump pasó del límite de 10 min y se le mató. Los días anteriores el job completaba en 9m14s / 9m33s y `pg_dump` cerraba limpio (PgBouncer sí ejecuta el reset en cierres normales).

**Evidencia que descarta hipótesis previa (Flyway baseline)**:

- `pg_tables` listado contra `pre-pool` (mismo URL que md-core) muestra `blister` + 11 tablas `qrtz_*`. Las tablas existen.
- `flyway_schema_history` (md-core, schema `public`) tiene 15 entradas iniciales, todas con `success=true`, instaladas el `2022-01-27 11:29:24`. Incluye `V0.0.0__Base`, `V0.0.7__Quartz`, etc. **No hay baseline-mark falso**.
- md-auth y md-resi-back tienen sus propias `flyway_auth_schema_history` / `flyway_resi_schema_history` — no hay cross-history conflict.
- `qrtz_scheduler_state` contiene **filas activas** con check-ins recientes de los pods de md-core (`md-core-6cc74897f8-cv2hn1778236420064`, intervalo 15 s). md-core **escribe correctamente** a la tabla en el caso normal.

**Por qué el patrón es bursty (no constante)**:

PgBouncer transaction-mode reusa los backends Postgres entre clientes. El `server_reset_query` de DO Managed Postgres **sólo se ejecuta cuando el backend se cierra** (timeout, pool sizing), no entre transacciones. Mientras un backend esté vivo y haya sido contaminado por algún cliente que hizo `SET search_path = X`, todas las transacciones subsecuentes en ese backend heredan el setting. Cuando el backend muere o el cliente "limpia" con `SET search_path = DEFAULT`, vuelve la normalidad. De ahí los bursts coincidiendo con backend-rotation interno.

Quién contamina el `search_path` no es 100% reproducible desde fuera, pero candidatos:
- Internamente DigitalOcean podría tener consumidores (monitoring, backup) que usen PgBouncer y dejen `search_path = pg_catalog`.
- Algún flow Hibernate / consulta JPA pesada en md-core o md-resi-back que cambie schema temporalmente.
- Una sesión humana de `psql` que olvidó `RESET search_path`.

**Por qué el código está OK pero el sistema falla**:

- `quarkus.quartz.clustered=true` + `store-type=jdbc-cmt` (en `md-core/.../application.properties:84-88`) es razonable.
- El SQL de Quartz son SELECTs unqualified (`SELECT ... FROM QRTZ_LOCKS`). Postgres pliega → `qrtz_locks`. Resuelve correctamente con `search_path = "$user", public`. Falla con cualquier `search_path` que no incluya `public`.
- Lo mismo aplica a Hibernate y la entidad `Blister`: queries unqualified, dependen del `search_path`.

**Impacto en producción**:

- **Funcional (Quartz)**: cuando el cluster check-in falla intermitentemente, Quartz cree que la otra réplica "ha muerto" e inicia recovery, pero también falla. Los jobs in-memory (`start-mode=forced`) se siguen ejecutando → recordatorios de medicación se disparan, pero el cluster recovery está roto durante esos burst windows. Riesgo latente de **doble-disparo** entre las 2 réplicas (sin coordinación funcional via `qrtz_locks`).
- **Funcional (Hibernate / `blister`)**: análogo. El error `relation "blister" does not exist` aparece esporádicamente; queries que usan otra ruta de código siguen funcionando. Hay un mosaico de comportamiento "a veces sí, a veces no".
- **Observabilidad**: ~430 ERRORs/día spurios contaminan Loki. Las alertas se desensibilizan (cry-wolf).
- **Customer-visible**: no verificado — pero el doble-disparo de jobs WhatsApp/MQTT puede haber producido mensajes duplicados a pacientes en algún momento.

**Fix aplicado** (k8s repo, branch `fix/md-backup-bypass-pgbouncer`, deploy en pre 2026-05-09):

`k8s/environments/pre/kustomization.yaml` configmap `s3-backup-config`:
```diff
- DB_NAME=pre-pool
- DB_PORT=25061
+ DB_NAME=defaultdb
+ DB_PORT=25060
```

Y `activeDeadlineSeconds` para el CronJob:
```diff
- (default 600 desde base)
+ activeDeadlineSeconds: 1800
```

**Por qué este enfoque y no otros más globales** (sopesados y descartados):

- **Bypass PgBouncer en md-core**: arregla el síntoma pero md-core con `max-size=50`×2 pods = 100 conexiones directas saturaría el budget de Postgres (límite ≈ 100 en DO). Riesgo de cluster crash por "too many connections" bajo cualquier burst de tráfico. Demasiado caro por la cuenta.
- **`quarkus.quartz.table-prefix=public.QRTZ_`** en md-core: defensivo pero no ataca el origen — la contaminación seguiría afectando a Hibernate (`blister`) y futuras queries unqualified.
- **Cambiar el pool de DO a session-mode**: viable pero afectaría a md-auth, md-resi-back, md-core simultáneamente y reduce el multiplexing global. Demasiado destructivo para fix puntual.

El bypass en **md-backup** es el mínimo cambio quirúrgico: es 1 cliente, 10 min/día, no se beneficia del pool, y elimina la fuente. Los demás servicios siguen como están.

**Validación**:

```bash
kubectl --context=do-fra1-md-pre-cluster create job \
  --from=cronjob/md-backup-cronjob md-backup-fix-validation
```

Resultado del run: el job arrancó conectando directo a 25060 (bypass confirmado), pero pg_dump abortó con `server version mismatch: server version: 17.9; pg_dump version: 16.13`. DO Managed Postgres se actualizó a 17.x en algún punto y el cliente de Alpine 3.20 sólo trae pg_dump 16.13 — el route por PgBouncer enmascaraba el problema porque el pooler reportaba su propio protocolo. Causa raíz para el chain de Quartz sigue siendo correcta y el bypass es necesario; el version mismatch es un segundo bug encadenado que sólo se vio al apartar PgBouncer.

**Fix encadenado (md-backup repo, branch `fix/pg17-client-and-pipefail`)**:

- `Dockerfile`: Alpine 3.20 → 3.21, `postgresql-client` → `postgresql17-client` (17.9, coincide con el servidor).
- `backup_pg.sh`: añadido `set -eu` + `set -o pipefail`, sanity-check de tamaño post-dump (>1 KB), y arreglado un bug de interpolación pre-existente — `pg_backup_$DB_NAME_$NOW.tar.gz` evaluaba a `pg_backup_<dow>.tar.gz` (con `$DB_NAME_` como variable inexistente) en lugar de `pg_backup_<dbname>_<dow>.tar.gz`. Cambiado a `${DB_NAME}_${NOW}` con braces.

Validación pendiente: tras CD que empuje `gailen/md-backup:latest` con Alpine 3.21, re-ejecutar `kubectl create job --from=cronjob/md-backup-cronjob md-backup-fix-validation-2`. El job debería ahora completar con tarball >> 1 KB y exit 0 real (no enmascarado).

**Hallazgo colateral del debugging** (resuelto junto con el version mismatch):

Los `pg_backup_*.tar.gz` históricos en S3 son todos de **20 bytes** (header gzip vacío). Llevaban fallando silenciosamente desde la actualización de DO a Postgres 17 — el `pg_dump` 16.13 abortaba con version mismatch, y como `backup_pg.sh` no tenía `set -o pipefail`, el exit code de gzip (0 sobre input vacío) enmascaraba el fallo. Resuelto en `fix/pg17-client-and-pipefail` con pipefail + size-guard que hace exit 1 si el tarball resulta < 1 KB.

**Referencias**:

- Cambio aplicado: `k8s/environments/pre/kustomization.yaml@fix/md-backup-bypass-pgbouncer`
- Script backup: `md-backup/backup_pg.sh`
- DO Managed Postgres pool config: `pre-pool` → `defaultdb`, mode=transaction, size=90 (no tocado)
- Reproducción del leak: `kubectl run psql-debug --image=postgres:15-alpine -- psql 'postgresql://.../pre-pool' -c "SET search_path=pg_catalog; SELECT * FROM qrtz_scheduler_state LIMIT 1;"` reproduce el error idénticamente.
- Loki query de muestra: `{cluster="pre", container="md-core"} |~ "relation .* does not exist"`

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
