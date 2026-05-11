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

---

## Identificadores de negocio (MDC en md-core)

md-core emite los logs en JSON con campos a nivel raíz para
`phone`, `blister`, `treatment`, `seguimiento`, `user` cuando el
contexto los conoce. Vector NO los promueve a labels en Loki (saturaría
la cardinalidad), así que el patrón base es:

> bajar las líneas raw y filtrar/agregar **client-side con `jq`**

Probado: el filtro server-side `| json | blister="X"` falla en
combinación con la estructura nested de vector (campo `kubernetes`
lleva sub-objetos). Mantenemos el `| json` server-side fuera y tiramos
de jq sobre `.line`.

Campos disponibles en `.line` (no todos siempre populados; ausencia o
valor `"-"` significa "el código que emitió este log no tenía contexto"):

| campo         | qué es                                                          |
|---------------|-----------------------------------------------------------------|
| `phone`       | número E.164 con `+` (e.g. `+34628007291`)                      |
| `blister`     | código corto del blister físico (e.g. `H7BXCI`, `99TGJG`)       |
| `treatment`   | id numérico del tratamiento (e.g. `12878326`)                    |
| `seguimiento` | id numérico del seguimiento del paciente                         |
| `user`        | nombre o id del paciente (e.g. `Carlota`, `0000000085`)          |
| `level`       | INFO / WARN / ERROR                                             |
| `message`     | el mensaje formateado                                           |

### #20 — Top identifiers en las últimas 24h

Top blisters más activos (excluye los `"-"` y los `null`):

```bash
logcli query --quiet --output=jsonl --limit=5000 --since=24h \
  '{cluster="pre", container="md-core"}' \
  | jq -r '.line | fromjson? | .blister // empty | select(. != "-")' \
  | sort | uniq -c | sort -rn | head -20
```

Resultado real (24h, 9-may-2026):

```
  27 JC1PKZ
  23 VE6MSK
  22 LEHXZE
  21 8H5XI9
  19 MVQQFL
  ...
```

Loop para cualquier campo:

```bash
for field in phone blister treatment seguimiento user; do
  echo "=== top $field ==="
  logcli query --quiet --output=jsonl --limit=5000 --since=24h \
    '{cluster="pre", container="md-core"}' \
    | jq -r --arg f "$field" '.line | fromjson? | .[$f] // empty | select(. != "-")' \
    | sort | uniq -c | sort -rn | head -5
done
```

> Si el `--limit=5000` se queda corto (la query es de 24h y md-core emite
> ~8500 líneas/día), sube el límite o reduce la ventana con `--since=6h`.

### #21 — Toda la actividad de un identificador concreto

Drill-down: dame todos los eventos relacionados con un blister,
ordenados cronológicamente. Aquí sí filtramos en jq:

```bash
BLISTER=JC1PKZ

logcli query --quiet --output=jsonl --limit=2000 --since=7d \
  '{cluster="pre", container="md-core"}' \
  | jq -r --arg b "$BLISTER" '
      .line | fromjson? | select(.blister == $b)
      | [.timestamp // "-", .level, .message] | @tsv' \
  | sort
```

Lo mismo por teléfono o por tratamiento:

```bash
PHONE='+34628007291'
logcli query --quiet --output=jsonl --limit=2000 --since=7d \
  '{cluster="pre", container="md-core"}' \
  | jq -r --arg p "$PHONE" '
      .line | fromjson? | select(.phone == $p)
      | [.level, .message] | @tsv'

TREATMENT=12878326
logcli query --quiet --output=jsonl --limit=2000 --since=7d \
  '{cluster="pre", container="md-core"}' \
  | jq -r --arg t "$TREATMENT" '
      .line | fromjson? | select(.treatment == $t)
      | [.level, .message] | @tsv'
```

### #22 — Caso de paciente: del blister al teléfono y al tratamiento

Cuando llega una queja "el blister X no manda mensajes", la cadena
útil suele ser: encontrar el `(blister, treatment, phone)` asociado y
mirar errores recientes.

```bash
BLISTER=JC1PKZ

# 1) Tripleta única (blister, treatment, phone) que aparece en logs
logcli query --quiet --output=jsonl --limit=2000 --since=7d \
  '{cluster="pre", container="md-core"}' \
  | jq -r --arg b "$BLISTER" '
      .line | fromjson? | select(.blister == $b and .phone != null and .phone != "-")
      | [.blister, .treatment, .phone] | @tsv' \
  | sort -u

# 2) Sólo errores que mencionen ese blister
logcli query --quiet --output=jsonl --limit=2000 --since=7d \
  '{cluster="pre", container="md-core"}' \
  | jq -r --arg b "$BLISTER" '
      .line | fromjson? | select(.blister == $b and .level == "ERROR")
      | .message'

# 3) Mensajes WhatsApp salientes hacia el phone descubierto en (1)
PHONE='+34628007291'
logcli query --quiet --output=jsonl --limit=200 --since=24h \
  '{cluster="pre", container="md-core"} |~ "FROM:.*TO:.*MSG:"' \
  | jq -r --arg p "$PHONE" '
      .line | fromjson? | select(.phone == $p) | .message'
```

### #23 — Quiénes han enviado WhatsApp y a quién

Pares (FROM Twilio number, TO patient phone) en 12 h, por volumen:

```bash
logcli query --quiet --output=raw --limit=2000 --since=12h \
  '{cluster="pre", container="md-core"} |~ "FROM:.*TO:.*MSG:"' \
  | grep -oE 'FROM: \S+ - TO: \S+' \
  | sort | uniq -c | sort -rn | head -10
```

> Útil para detectar "este paciente está recibiendo demasiados mensajes"
> o "este FROM (Twilio number) ya no funciona" antes de mirar Twilio
> console. `--output=raw` aquí está bien porque la firma `FROM ... TO ...`
> está literalmente en el mensaje.

### #24 — Adherencia: confirmadas vs olvidadas por usuario

```bash
for ev in "TOMA CONFIRMADA" "TOMA OLVIDADA"; do
  echo "=== $ev (24h) ==="
  logcli query --quiet --output=jsonl --limit=2000 --since=24h \
    "{cluster=\"pre\", container=\"md-core\"} |~ \"$ev\"" \
    | jq -r '.line | fromjson? | .user // empty | select(. != "-")' \
    | sort | uniq -c | sort -rn | head -10
done
```

### #25 — Verificar que un blister está siendo "scheduleado"

```bash
BLISTER=JC1PKZ
logcli query --quiet --output=jsonl --limit=200 --since=24h \
  "{cluster=\"pre\", container=\"md-core\"} |~ \"scheduling|scheduled|Solicitado informe\"" \
  | jq -r --arg b "$BLISTER" '
      .line | fromjson? | select(.blister == $b) | .message'
```

Si el blister existe en BD pero no aparece nada aquí en 24h, el
`NotificationSchedulerService` no lo está procesando — buen punto
de partida para investigar el caso.

### Tip: ver el shape completo de una línea

Cuando el campo no está donde esperas (vector cambia, md-core añade
nuevos MDCs), inspecciona una línea representativa:

```bash
logcli query --quiet --output=jsonl --limit=1 --since=1h \
  '{cluster="pre", container="md-core"} |~ "Blister.*available"' \
  | jq '.line | fromjson | {message, blister, treatment, phone, user, "all-keys": keys}'
```

---

## Exploración 2026-05-09 — anomalías de blister numérico y de WhatsApp

Ventana: 30 h alrededor del 9-may-2026 (lo que retiene Loki desde
arranque del stack).

### Hallazgo A — MDC `blister` contaminado por dos espacios de IDs

El MDC `blister` carga **dos esquemas de id distintos** según el code path:

| Origen del log                                            | Forma del id      | Ejemplo                |
|-----------------------------------------------------------|-------------------|------------------------|
| Resto de md-core (jobs, scheduler, WhatsApp, sync)        | 6-char alfanum    | `JC1PKZ`, `H7BXCI`     |
| `com.medicaldispenser.shc.http.ShcController` `SHCEvent`  | numérico pequeño  | `0`, `837`, `1168`     |

13 IDs numéricos distintos vistos en 30 h, todos con el patrón
`SHCEvent: Device: %s, Blister: <numérico> - <evt>(...) => ...`.
El `0` aparece como sentinel ("Blister insertado correctamente"
con id 0) y huele a default no-inicializado.

**Impacto operativo**: las recetas #21 y #22 (drill-down por
blister) **no encuentran** los eventos del SHC físico cuando se
busca por el token alfanumérico. Si un paciente reporta un
problema con `H7BXCI`, la pista del dispositivo (qué tomas
registró, errores hardware, etc.) se queda fuera del resultado.

**Fix propuesto** (md-core, no urgente): que `ShcController`
mapee el id numérico del firmware al token alfanumérico antes
de poblar el MDC, o que use un MDC distinto (`shcBlister`) y
documentemos los dos.

### Hallazgo B — UX: usuario reconfirma toma ya registrada (Fernando, +34618039024)

Tres mensajes idénticos `"La última toma ya se ha registrado, ya
hablamos en la siguiente."` enviados en 41 h, con SIDs inbound
distintos cada vez. Es el usuario pulsando el botón "confirmar"
**después de que el sistema ya cerró la toma**.

**Issue UX, no bug**: la respuesta es informativa pero no rompe
el bucle conversacional — el paciente no sabe **cuándo** será la
siguiente y vuelve a pulsar.

**Fix propuesto** (md-core, conversational layer): incluir hora
o blister-info en la respuesta. Algo como `"Hoy ya estás al día.
La siguiente toma es a las HH:MM."`

### Hallazgo C — UX: doble respuesta a doble inbound (Francisco, +34647904694)

Dos veces en 30 h, Francisco mandó dos mensajes inbound separados
por **41–90 µs** (SIDs distintos). md-core los procesa en paralelo
y responde 👍 a cada uno. Resultado: el usuario recibe doble emoji.

**Issue UX**: probablemente cliente WhatsApp re-enviando, o
double-tap en interfaz. Ruido para el paciente.

**Fix propuesto** (md-core, `UserMessageReceiver`): dedup por
`(phone, message, ventana 5s)` antes de despachar. Implica una
tabla in-memory pequeña con TTL.

### Hallazgo D — Bug de logging: vCard logueado como `MSG: ` vacío

3 mensajes a `+34689028042` ("FARMACIA PRUEBA") en 52 µs:

```
14:55:04.563878 — ¡Hola FARMACIA PRUEBA!
14:55:04.563904 — Si quieres puedes añadirme como contacto...
14:55:04.563930 — <empty>
```

El tercero con `MSG:` vacío es casi seguro un envío de **vCard**
(tarjeta de contacto Twilio) — payload binario, body vacío. El
log line lo expone como ruido visual.

**Fix propuesto** (md-core,
`ContentEditorWhatsappChannel.send(...)`): cuando `mediaUrl !=
null`, loguear `MEDIA: <url>` en lugar de (o además de)
`MSG: <empty>`.

### Lo que NO encontré (importante para la confianza en la app WhatsApp)

- **0 hits** de `Error enviando template`, `Twilio.*error`,
  `whatsapp.*error` en 30 h.
- **No bombing**: 1 sólo número FROM, máximo 6 mensajes a un
  mismo TO en 30 h.
- **No retry-loop del backend**: las repeticiones identificadas
  son siempre triggered por inbound del usuario, no por reintentos
  internos.

El canal WhatsApp está sano funcionalmente; los issues son de UX
y logging, no de fiabilidad de envío.

---

## Exploración 2026-05-11 — consolidación de errores 96h

Ventana: **2026-05-08T12:10 → 2026-05-11T19:01 UTC** (~80 h, todo
lo retenido por Loki desde arranque del stack).

- Total líneas md-core: **27 139**
- Líneas ERROR/Exception:  **1 092**  (4 %)
- Errores con identifier de negocio: **645**  (59 %)
- Errores de infra sin identifier:    **447**  (41 %)

Ningún error de transporte cae sin contexto identificable: o
adjuntan `blister`/`treatment`/`user` o nacen de un logger
infra (`JobStoreCMT`, `JobRunShell`, `ErrorLogger`, `SecurityFilter`,
`QuarkusErrorHandler`, `AbstractResteasyReactiveContext`,
`ShcConfigurationEventsEmitter`).

### Patrón temporal — pico nocturno **23:00 UTC** todos los días

Distribución por hora UTC (filtrada a horas con >100 errores):

```
2026-05-08T23  127  ⚠️
2026-05-09T05  214  ⚠️   ← incidente Quartz/PgBouncer (ya documentado)
2026-05-09T23  125  ⚠️
2026-05-10T23  126  ⚠️
```

El pico de las 23:00 UTC son los **mismos 119 blisters cada noche**
(intersección 3 noches = 119, casi 1:1). Loggers responsables:

```
119  PeriodicNotificationGenerator   (NO SE HA ENCONTRADO EL dailyReport ...)
  4  IntakeReminderNotificationJob   (recordatorio sin toma)
  4  UserMessageReceiver             (incoming WhatsApp normal, no error)
```

Es ruido sistemático: un job nocturno itera sobre los blisters
activos y para 119 de ellos no encuentra `dailyReport SOLICITADO`
ni `dailyReport PROGRAMADO`. 119 blisters distintos × 2-3 errores
cada uno = ~250-300 ERROR lines/noche que están siendo emitidos
sin que indique fallo de servicio al paciente.

### Hallazgo E — dailyReport not-found es ruido crónico de TODOS los blisters activos

Composición de los **437** `PeriodicNotificationGenerator` ERROR:

| variante                                  | hits | blisters distintos |
|-------------------------------------------|-----:|-------------------:|
| `dailyReport SOLICITADO not found`        |  329 |       151          |
| `dailyReport PROGRAMADO not found`        |  108 |       108          |

- 107 blisters reciben **ambos** errores (mismo blister, dos
  variantes).
- 152 blisters tienen al menos uno → básicamente todos los
  blisters activos en producción (recuerda, eran 237 totales,
  pero los 80-100 con muy poca actividad son demo/desuso).
- Sólo **1 blister** sale en PROGRAMADO sin SOLICITADO (caso raro,
  probable race).

**El wording del log es engañoso. Tras revisar el código
(`PeriodicNotificationGenerator.java:67-91, 100-133`)**: el ERROR
**no significa** "el report no se ha creado todavía". Es la rama
final de un `forEach` que itera sobre
`seguimientoRepo.findByTratamientoSeguimientoInforme(...)`, cuya
query es:

```java
"activo = true AND tratamiento = ?1 AND seguimientoinforme is true"
```

El ERROR dispara cuando el blister está activo pero **ningún
seguimiento (paciente o cuidador) tiene `seguimientoinforme = true`**.
Es decir, nadie en el círculo de ese paciente ha activado la opción
de "recibir informe periódico".

Eso es legítimo: muchos pacientes prefieren sólo SHC + reminders y
no informes; el flag puede ser `false` por defecto. **152 / 237
blisters ≈ 64 %** están así configurados → **no es un fallo, es la
configuración mayoritaria del sistema**.

**Implicaciones**:

1. **Bug filtro alerta `MdCoreNovelErrorBurstPre`**: excluye sólo
   `dailyReport SOLICITADO` y `PeriodicNotificationGenerator`,
   pero **no `dailyReport PROGRAMADO`**. Resultado: el wrapper
   Quartz `ErrorLogger`/`JobRunShell` con `Job
   ReportNotifications.PATIENT...threw an exception` y los
   `PROGRAMADO` no excluidos disparan la alerta como "novel" cuando
   son la misma fuente. Ya disparó 2 veces (10-may 13:05 y 22:05).
2. **Deuda funcional en md-core**: ese `log.errorf` debería ser
   `log.infof` o `log.debugf` — el caso "no hay suscriptores al
   informe" no es excepcional. ERROR-level se reserva para fallos
   reales (token inexistente → ya cubierto en la rama `else` del
   `ifPresentOrElse`, esa sí legítimamente ERROR).

### Hallazgo F — IntakeReminder NotFound concentrado en ~20 blisters "ruidosos"

**95** `IntakeReminderNotificationJob` errors, repartidos en sólo
**20 blisters distintos**, top-10:

```
11  72IFY5
10  KCSI8H
 9  99TGJG
 8  I8F1I5
 8  E4UE5F
 8  CB9TUH
 7  MFTBP6
 7  D61T82
 5  8H5XI9
 3  NIZXID
```

Cada error: `No se encuentra la toma para lanzar el recordatorio
con el trigger Trigger '<BLISTER>.REMINDER.YYYYMMDDHHMM.NN'`.

**Tras revisar el código (`IntakeReminderNotificationJob.java:35-63`)**:

```java
ofNullable(tomaRepo.findByBlisterTokenAndTimestamp(token, intake))
    .filter(t -> !(t.taken || t.missed))
    .map(t -> { /* envía reminder */ })
    .orElseGet(() -> { log.errorf("No se encuentra la toma ..."); });
```

El ERROR mezcla **dos casos distintos** sin distinguirlos:

- **(a) la toma no existe en BD**: `findByBlisterTokenAndTimestamp`
  devolvió null. Posible fallo real (toma borrada, treatment
  cancelado dejando trigger huérfano).
- **(b) la toma existe pero ya está `taken` o `missed`**: el
  `.filter` la descarta y cae también en `.orElseGet`. Esto pasa
  cuando **el paciente confirma la toma antes** (vía SHC físico o
  WhatsApp) de que el reminder dispare. Es **completamente normal**
  — Quartz dispara religiosamente aunque el reminder ya no haga
  falta.

Mezclar (a) y (b) bajo el mismo ERROR explica el patrón: los 20
blisters con más errores no son tratamientos "rotos", son los
blisters con **pacientes más diligentes confirmando rápido**.

Que sea solo 20 blisters específicos (y no todos los activos)
sugiere que la mayoría son del caso (b) pero hay sesgo: pacientes
con muchas tomas/día, o con tratamientos de `maxDelay` corto donde
la ventana entre toma real y reminder es mayor, son los que más
generan estos ERRORs benignos.

Intersección con dailyReport not-found: **10 de 20** también
sufren los errores del Hallazgo E. Que la mitad solape sugiere
que no hay correlación de causa raíz, sólo de actividad.

**Fix correcto en md-core**: separar las dos ramas del `orElseGet`
y dejar ERROR sólo para el caso (a).

### Hallazgo G — `/shc/event` 5xx — 51 fallos en 96 h, 22 concentrados en un solo burst

| Cuándo | Cuántos | Patrón |
|---|---:|---|
| 08-may 17:xx UTC | **22** | burst concentrado |
| resto (3 días) | ~29 | goteo continuo, ~1/h |

Todos los `Request failed` con `QuarkusErrorHandler` corresponden
a `/shc/event` (51) salvo 1 a `/user/paciente/1`. Es el endpoint
donde el SHC físico postea eventos de tomas.

El burst del 8-may 17:xx coincide con la franja horaria de comida
(19 Madrid) — momento natural de pico de eventos SHC. Pero 22 en
una hora es **alto** respecto al ~1/h habitual.

**Pendiente**: cruzar SIDs con los SHCEvents anteriores para
identificar qué tomas/blisters dispararon `IntakeNotFoundException`.
Necesitaríamos los IDs numéricos de blister del Hallazgo A —
otra razón para arreglar ese MDC.

### Hallazgo H — `No programming found for device` patrón cíclico

**49** ERRORs distribuidos en sólo **14 devices**, con cadencia
diaria muy regular:

```
2026-05-08T15  10   ← cada día a las 15:00 UTC
2026-05-09T15  10
2026-05-10T15  10
2026-05-11T15  10
```

Los 10 errores por día corresponden a los devices `0000001001`,
`0000001002`, `0000001005`–`0000001008` y algunos `00000000xx`
sueltos.

**Tras revisar el código (`ShcConfigurationEventsEmitter.java:71-91`)**:

```java
tratamientoRepo.findBySHCDevice(shcID).ifPresentOrElse(t -> {
    val progs = blisterRepo.findAllByTratamiento(t.id)
            .stream()
            .filter(b -> (b.fechaFin.isAfter(LocalDate.now()) || ...)
                       && b.fechaInicio.isBefore(LocalDate.now().plusDays(3)))
            .sorted(...)
            .map(ShcProgramming::calculateProg)
            .limit(2)
            .collect(...);
    if (progs.size() > 0) {
        sendConfiguration(shcID, progs);
    } else {
        log.errorf("No programming found for device %s", shcID);    // ← aquí
    }
}, () -> log.errorf("Device %s unknown. No programming sent.", shcID));
```

El ERROR dispara cuando el device **sí tiene tratamiento asociado**
(pasa el `ifPresentOrElse`), pero el filtro de "blisters activos en
±3 días" devuelve 0. Posibles causas legítimas:

- Tratamiento pausado o completado, device sigue asignado.
- Onboarding inicial — device asignado antes de que existan
  blisters próximos.
- Periodo de huelga del tratamiento.

La **otra rama** (`Device unknown. No programming sent.`) SÍ es
ERROR legítimo — un device hizo handshake pero no está en BD.

Pero la rama que dispara los 49 ERRORs/4 días es **expected** y
debería ser INFO/WARN. Sólo afecta a 14 devices estables, todos
con el patrón `0000001001-1008` (rango demo) o `00000000xx`
sueltos — probablemente tests o devices en limbo.

### Hallazgo I — SecurityFilter: cliente Delphi con token cruzado

**20** errors, todos idénticos:
```
Request with X-PHARMACY-ID=E26635037 doesn't match with token
issued for E60144326.
```

Concentrados en **11-may 16:50 → 20:43 UTC**, **goteando** (1-2 por
ventana de 5-30 min). Es decir: hoy mismo, en horario de operación.

**Sospechas**: un cliente Delphi configurado con el token de la
farmacia E60144326 está enviando peticiones con header
`X-PHARMACY-ID=E26635037`. Un único cliente mal configurado,
sostenido en el tiempo. Quizá un farmacéutico cambió de farmacia
y el binario quedó con creds antiguas.

**Acción**: contactar a operaciones para identificar la farmacia
E26635037 y revisar su configuración.

### Distribución por dimensión (resumen completo)

| Dimensión | Distintos | Notas |
|---|---:|---|
| blister con errores | **162** | de ~237 activos → 68 % afectados |
| treatment con errores | **148** | top: 9353813(14), 32292(13), 9356089(11) |
| user con errores | **15** | top: Sergio(20), Francesc(19), Juan(15) |
| device sin programación | **14** | mayoría demo (0000001xxx) |

**Interpretación**: los errores **no están concentrados en un
puñado de pacientes**. La mayoría de blisters activos sufre al
menos un error por sesión (mayormente el ruido nocturno del
dailyReport). Sólo el patrón IntakeReminder está realmente
concentrado (20 blisters específicos).

### Estado de las alertas — disparos detectados en 96 h

AM no guarda historial; reconstruyo evaluando condiciones contra Loki:

| Cuándo (UTC) | Alerta | Pico | Causa |
|---|---|---:|---|
| 09-may 03:10-03:50 | `MdCoreQuartzErrorAggravationPre` | 0.163 | Incidente PgBouncer/Quartz (documentado en INCIDENTS.md) |
| 10-may 13:05 | `MdCoreNovelErrorBurstPre` | 0.033 | Falso positivo: dailyReport PROGRAMADO + wrappers Quartz |
| 10-may 22:05 | `MdCoreNovelErrorBurstPre` | 0.033 | Falso positivo: mismo patrón |
| 10-may 06:10 | `MdCoreIntakeReminderErrorPre` | 0.013 | Patrón crónico (Hallazgo F) |
| 11-may 06:10 | `MdCoreIntakeReminderErrorPre` | 0.013 | Patrón crónico (Hallazgo F) |

### Acciones recomendadas

**Corto plazo (alerts tuning)**:

1. **Fix filtro `MdCoreNovelErrorBurstPre`** en
   `platform/observability/queries/pre/md-core-other-error-rate.yaml`:
   añadir a la exclusión `!~` los wrappers Quartz que repiten el
   ruido conocido:

   ```
   dailyReport PROGRAMADO
   ReportNotifications
   MissedIntakeNotifications
   IntakeNotifications
   JobRunShell
   ErrorLogger
   ```

   Sin esto, la alerta dispara periódicamente por ruido conocido.

2. **Re-calibrar `MdCoreIntakeReminderErrorPre`** o aceptar que es
   chronic-noise. Hoy dispara a 0.013 req/s (3 errores en 5 min)
   y eso es el comportamiento normal del sistema porque
   los 20 blisters con triggers huérfanos producen esto a diario.

**Medio plazo (deuda en md-core)** — todos verificados leyendo el
código fuente, no asumidos:

3. **Hallazgo E** (`PeriodicNotificationGenerator.java:86, 127`)
   — bajar `log.errorf` a `log.infof` o `log.debugf` cuando
   `enviado.get() == false`. El caso "ningún seguimiento con
   `seguimientoinforme=true`" no es excepcional, es la
   configuración mayoritaria del sistema.

4. **Hallazgo F** (`IntakeReminderNotificationJob.java:35-63`)
   — separar las dos ramas del `orElseGet`. Hoy mezcla "toma
   inexistente" (ERROR real) con "toma ya `taken`/`missed`"
   (no es error, paciente confirmó antes). El reorder sería:

   ```java
   val toma = tomaRepo.findByBlisterTokenAndTimestamp(token, intake);
   if (toma == null) {
       log.errorf(...);  // sólo aquí — toma inexistente
   } else if (toma.taken || toma.missed) {
       log.debugf("Toma ya confirmada/perdida, reminder no necesario");
   } else {
       /* envía reminder */
   }
   ```

5. **Hallazgo H** (`ShcConfigurationEventsEmitter.java:86`) —
   bajar a `log.warnf` o `log.infof` el caso "device tiene
   tratamiento pero sin blisters en ventana ±3 días". La rama
   `Device unknown` (línea 90) **sí** mantenerla en ERROR — eso
   sí es excepcional.

**Investigaciones puntuales**:

6. **Hallazgo G** — burst /shc/event del 8-may 17:xx UTC merece
   un drill-down con los SIDs específicos.

7. **Hallazgo I** — operaciones debería contactar farmacia
   E26635037 para reconfigurar.
