# Loki — query cookbook

Queries usadas para explorar/operar el sistema desde Loki. El stack está en
el droplet de plataforma (`logs.platform.fmd.fagorhealthcare.com`), con
basic-auth en el edge Caddy. Cada query lleva un identificador (`#NN`) para
poder relanzarla por nombre.

## Setup (una vez por sesión)

```bash
export LOKI_ADDR=https://logs.platform.fmd.fagorhealthcare.com
export LOKI_USERNAME=vector
export LOKI_PASSWORD=$(grep ^LOKI_AUTH_PASS= \
  /Volumes/SHEVEK_EXTERNO/Projects/FagorHealthcare/terraform/platform-credentials.txt \
  | cut -d= -f2)
```

Convención de tiempos: el cluster está en UTC. La franja horaria local
(Madrid) es UTC+2 en verano. `--from`/`--to` aceptan RFC3339 o relativos
(`-1h`, `--since=24h`).

---

## Exploración 2026-05-08 — eventos en pre desde 06:00 Madrid

Ventana: `2026-05-08T04:00:00Z` → ahora.

### #01 — Inventario de streams activos

Qué apps/containers han emitido al menos un log.

```bash
logcli series '{cluster="pre"}' --since=12h
```

### #02 — Conteo de eventos por container

Para sumar a "cuánto" sin perderse en time-series, usar `instant-query`:

```bash
logcli instant-query --quiet \
  'sum by (container) (count_over_time({cluster="pre"}[12h]))'
```

Resultado típico (12h, 2026-05-08):

| events | container |
|---|---|
| 9 359 | controller (ingress-nginx) |
| 1 477 | md-core |
|   531 | md-resi-front |
|    67 | md-pwa |
|    42 | md-resi-back |
|    38 | md-auth |

### Hallazgos 2026-05-08 (06:00 → 16:00 Madrid)

**Status del ingress (8304 OK, 11 514 total)**:

| status | count | nota |
|---|---|---|
| 200 | 8 304 | OK |
| 204 | 599 | No Content (probable health-check / actualizaciones vacías) |
| 308 | 126 | redirects http→https |
| 504 | **105** | **Gateway Timeout** — ver hallazgo abajo |
| 404 | 57 | rutas inexistentes |
| 400 | 38 | bad request |
| 500 | 9 | error interno |
| 304 | 4 | not-modified |
| 401 | 4 | challenges de auth |
| 403 | 2 | forbidden |
| 499 | 2 | client closed |
| 101 | 1 | switch protocol (websocket) |

**Hallazgo A — concentración de 504 en `/vN/actualizacion`**

Las 105 timeouts (~1% del total ingress) **TODAS** son sobre el endpoint
`POST /v4/actualizacion?last=X HTTP/1.0` o su equivalente `/v5/`.
Top 3 victims:
- 50× `POST /v4/actualizacion?last=15`
- 32× `POST /v4/actualizacion?last=17`
- 7× `POST /v5/actualizacion?last=17`

Misma forma de URI, mismo verbo, mismo cliente probable (HTTP/1.0
sugiere agente legacy — Indy/Delphi). Indica un endpoint backend
lento que hay que perfilar.

**Hallazgo B — `IntakeNotFoundException` en md-core**

44 lineas con error/exception en 12h (~3.7/h). El cluster dominante
es `Request failed` (9×) provocado por:

```
com.medicaldispenser.services.IntakeNotFoundException:
  No encuentro toma [N] para tratamiento [12915710], del blister con id de carga [0].
  at ShcListenerService.findCurrentIntakeForTreatment(ShcListenerService.java:118)
```

- Aparece `tratamiento [12915710]` repetido (un solo paciente afectado).
- Las tomas piden índices distintos (`[0]`, `[26]`, …) y el blister
  reporta `id de carga [0]` — sugiere desync entre el SHC y la
  asignación de tomas en backend, o un blister sin cargar (id 0).
- Cada error genera un 500 que el ingress también ve.
- Endpoint: `/shc/event` → `ShcController.shcEvent` → confirmIntake / missedIntake.

**Status md-resi-front (frontend Cinfa)**: 533 eventos, 525 × 200,
3 × 400, 1 × 206. Sano.

**md-auth**: muy poco tráfico (38 eventos en 12h), pod productivo
pero idle. Logs internos son JSON estructurado de Quarkus.

### #03 — Distribución de status HTTP en el ingress

```bash
logcli instant-query --quiet \
  'sum by (status) (count_over_time(
       {cluster="pre", container="controller"}
       | json
       | __error__=""
       [12h]))'
```

`json | __error__=""` parsea cada línea como JSON y descarta las que
no parseen (eventos de stderr del controller, líneas de startup, etc.).

### #04 — Top URIs con un status concreto (ej: 504)

```bash
logcli query --quiet --output=jsonl --limit=200 --since=12h \
  '{cluster="pre", container="controller"}
   | json | status="504"
   | line_format "{{.request}}"' \
  | jq -r '.line' | sort | uniq -c | sort -rn | head -10
```

### #05 — Líneas con error/exception en un servicio

```bash
logcli instant-query --quiet \
  'sum(count_over_time(
       {cluster="pre", container="md-core"}
       |~ "(?i)error|exception"
       [12h]))'
```

### #06 — Top mensajes de error (agregado por message-prefix)

```bash
logcli query --quiet --output=jsonl --limit=200 --since=12h \
  '{cluster="pre", container="md-core"}
   |~ "(?i)error|exception"
   | json
   | line_format "{{.message}}"' \
  | jq -r '.line[:100]' | sort | uniq -c | sort -rn | head -10
```

`message[:100]` agrupa errores que comparten prefijo (ignora UUIDs y
timestamps colados). Para drill-down de uno concreto, filtrar por ese
prefijo y mirar el `stackTrace`:

```bash
logcli query --quiet --output=jsonl --limit=5 --since=12h \
  '{cluster="pre", container="md-core"} |= "Request failed" | json' \
  | jq -r '.line | fromjson | "--- \(.sequence) ---\n\(.message)\n\(.stackTrace)"' \
  | head -50
```

---

## Investigación 2026-05-08 — Hallazgo A: 504 sobre `/vN/actualizacion`

### Conclusión

Google Sheets API devolvió **503 ("service is currently unavailable")**
durante 27 min sobre el documento `NOTICIAS`
(`1FX6Q5RORHiKEIuQR4QToN0yeK-LRH8TMultXwQgGJeg`). El contrib
`node-red-contrib-google-sheets@1.1.2` reintenta sin presupuesto, y
nginx corta a los 60 s con `proxy_read_timeout`. Como NOTICIAS está
**en serie** dentro del flow de v4/v5 pero NO en /v3/, sólo v4/v5
caen.

Tras las 13:49 UTC los 503 paran y /v4/v5 vuelven a 200 con latencias
normales (1-2 s). No sabemos si fue resolución espontánea de Google
o intervención humana sobre la hoja — para distinguirlo hay que mirar
el version history del propio sheet en Google Drive.

### Arquitectura

`nrapi.fmd.fagorhealthcare.com` (ingress `nodered-api-ingress`) manda
`/` a `md-node-red:1880`. Las `/vN/actualizacion` están servidas desde
**NodeRed**, NO desde ningún backend Java. El proyecto activo es
`/data/projects/FMDFlows/flows.json` (la snapshot local en
`k8s/data/projects/FMD3/flows.json` está obsoleta — llega hasta v3).
Service account: `cuenta-node-red@medical-dispenser.iam.gserviceaccount.com`.

### Por qué v3 vive y v4/v5 caen — diferencia estructural

Cadena (todo secuencial hasta `http response`):

| Endpoint | Hojas que toca | NOTICIAS? | Profundidad a `http response` |
|---|---|---|---|
| /v3 | `10KS…` PANEL + `1LX4…` LOG (4 ops) | **NO** | depth 6 |
| /v4 | + `1FX6Q5R…` **NOTICIAS** (CONFIGURACION + NOTICIAS) (6 ops) | **SÍ** | depth 10 |
| /v5 | + `1FX6Q5R…` **NOTICIAS** + VERSION_MAQUINAS (7 ops) | **SÍ** | depth 12 |

Cualquier sheet que esté en serie y devuelva 503 cuelga la cadena
hasta el timeout del ingress.

### Cadena de evidencia

1. **Patrón temporal**: 105 504s en una ventana única de 40 min
   (13:13–13:52 UTC = 15:13-15:52 Madrid). Antes y después: cero.

2. **`request_time` (campo `compression` del log nginx parseado)**:
   - 200 OK durante la misma ventana: n=17, p50=1.61 s, max=2.41 s
   - 504s: n=105, min=60.04 s, max=61.98 s, **avg=60.01 s**

   Los 60.0 s clavados son la firma del `proxy_read_timeout` por
   defecto de nginx.

3. **Aislamiento del fallo**:
   - /v4/actualizacion: 2 OK / 93 504 / 2 client-closed
   - /v5/actualizacion: 0 OK / 12 504
   - /v3/actualizacion: 4 OK / 0 504 — perfectamente sano

4. **No es load**: a las 10:23 UTC había 10 req/min sobre el mismo
   endpoint con 100 % éxito. Durante la incidencia el rate fue 1-7
   req/min.

5. **No es ISP/cliente**: 68 IPs distintas afectadas, varios /16
   (Movistar, Vodafone, Orange, Telefónica B2B). 37 de esas IPs
   también consiguieron 200s ese día → la misma instalación a veces
   funciona, a veces falla.

6. **Smoking gun en logs de NodeRed** (kubectl directo, NodeRed no
   está en Loki todavía):

   ```text
   8 May 15:22:27 [error] [GSheet:NOTICIAS 1] The API returned an
                  error: Error: The service is currently unavailable.
   8 May 15:26:46 [error] [GSheet:NOTICIAS 1] ...
   ... (13 errores entre 15:22 y 15:49 Madrid)
   ```

### Contexto histórico — los 503 son recurrentes

Los logs de NodeRed (11 días, desde 28-Apr) muestran que los 503
transitorios de Sheets API son **un patrón crónico**, no un evento
aislado:

| Sheet | Frecuencia | Notas |
|---|---|---|
| `Hoja Eventos SHC` | TODOS los días ~04:03 UTC | ~6 errores/noche, pinta de cron o trigger Apps Script |
| `Hoja Calculo Info Maquina` | 28-Apr 12:02 (5 errores en 50 s) | puntual |
| `AUTORIZACIONES` | 1-May 19:52 (1 error) | puntual |
| `NOTICIAS 1` | 8-May 13:22-13:49 UTC | la incidencia documentada aquí |

NOTICIAS no había fallado nunca antes en los 11 días de log → es
plausible que fuera un blip de Google sobre ese shard concreto. Pero
estructuralmente, es **una cuestión de tiempo** que vuelva a pasar
en cualquier sheet que toquemos en el camino crítico.

### Cómo verificar si fue blip de Google o edición humana

Acción manual (requiere acceso a la hoja con cuenta Google):

1. Abrir `https://docs.google.com/spreadsheets/d/1FX6Q5RORHiKEIuQR4QToN0yeK-LRH8TMultXwQgGJeg/edit`
2. *Archivo → Historial de versiones → Ver historial* — buscar
   ediciones entre 15:13 y 15:53 hora Madrid del 8-May
3. *Extensiones → Apps Script → Ejecuciones* — buscar runs en esa
   franja

Si no hay edición ni Apps Script en esa ventana, fue Google.

### #07 — Distribución temporal de 504s (HH:MM)

```bash
logcli query --quiet --output=raw --limit=2000 --since=18h \
  '{cluster="pre", container="controller"} | json | status="504"' \
  | jq -r '.logline' \
  | grep -oE '2026:[0-9]{2}:[0-9]{2}' | cut -d: -f2-3 \
  | sort | uniq -c | sort -k2
```

### #08 — Latencia de los OK (mismo endpoint, misma ventana)

```bash
logcli query --quiet --output=raw --limit=2000 \
  --from='2026-05-08T13:10:00Z' --to='2026-05-08T13:55:00Z' \
  '{cluster="pre", container="controller"} |~ "actualizacion" | json | status="200"' \
  | jq -r '.compression' | sort -n \
  | awk 'BEGIN{c=0}{a[c++]=$1; s+=$1}
         END{print "n="c, "min="a[0], "p50="a[int(c*0.5)], \
                  "p95="a[int(c*0.95)], "max="a[c-1], "avg="s/c}'
```

`compression` es como `parse_nginx_log` (combined) etiqueta el último
campo numérico del log; en este ingress es `$request_time` (segundos
con micros).

### Acciones de seguimiento

- [ ] Añadir `node-red` a `kubernetes_filter_1` en
      `k8s/environments/pre/vector/vector.yaml` para que NodeRed
      escupa a Loki. Estos errores los detectamos por kubectl manual
      sólo porque el pod tenía 11 días de log retenidos en stdout —
      sin Loki estos eventos se perderían silenciosamente.
- [ ] Cachear `NOTICIAS` en NodeRed (`flow.set` con refresh en
      background cada N minutos, fail-open al último valor en
      memoria). Es la acción de mayor rentabilidad: blinda /v4/v5
      contra futuros blips de Google sin tocar la lógica de negocio.
- [ ] Investigar por qué `Hoja Eventos SHC` falla con 503 a las
      04:03 UTC todos los días — es un patrón demasiado consistente
      para ser ruido aleatorio. Probable cron/trigger nuestro o de
      Google.
- [ ] Endgame: migrar AUTORIZACIONES + NOTICIAS a Postgres con un
      endpoint en md-core. El sheet como BD es frágil por diseño y
      no escala con el número de DPDs activos.

### Lo que NO arregla esto

- Subir `proxy_read_timeout` del ingress a 90/120 s — sólo cambia
  cuándo se rinde nginx; los clientes Delphi siguen sin recibir
  respuesta útil porque no se reintentan.
- Reintentar en el cliente — los Indy son legacy, no se les puede
  pedir cambio de comportamiento.
- Esperar — los 503 transitorios de Sheets son recurrentes en este
  histórico, va a volver a pasar.

### Datos clave (para futuras referencias rápidas)

- Sheet de **AUTORIZACIONES (PANEL)** (compartido v1-v5):
  `10KSkhnxJguTUlUt_hUCCQ16UykPXL7lB-hoCxawc6fg`
- Sheet de **NOTICIAS** (sólo v4/v5):
  `1FX6Q5RORHiKEIuQR4QToN0yeK-LRH8TMultXwQgGJeg`
- Sheet de **LOG histórico** (1LX4…) — append-only desde todos los flows
- Service account: `cuenta-node-red@medical-dispenser.iam.gserviceaccount.com`
- Proyecto NodeRed activo: `/data/projects/FMDFlows/flows.json`
