# Observability — Authentication & Access Control

Esta nota cubre cómo se autentican los humanos para acceder a la
plataforma de observabilidad (`*.platform.fmd.fagorhealthcare.com`),
cómo se añaden/quitan operadores, y el plan de migración del provider
cuando Fagor Healthcare confirme su IdP corporativo.

Aplica desde la rama `feat/oauth2-proxy-portal` en adelante. Antes de
ese cambio se usaba `basic_auth` con una credencial compartida única
(documentada en `terraform/platform-credentials.txt`).

## Visión general

```
Browser ─HTTPS─► Caddy (TLS edge) ──┬─► oauth2-proxy ──► GitHub OAuth
                                    │       │
                                    │       │ (allowlist + org check)
                                    │       ▼
                                    │   [ user verified ]
                                    │       │
                                    ├──► Loki  (logs.platform.*)
                                    ├──► Alertmanager (alerts.platform.*)
                                    ├──► Perses (dashboards.platform.*)
                                    └──► Portal estático (platform.fmd.*)

Vector ──basic_auth──► Caddy ──► Loki  (/loki/api/v1/push)
                                       (NO toca oauth2-proxy: vector
                                        no habla OAuth2.)

docker CLI ──basic_auth──► Caddy ──► Zot  (registry.platform.*)
                                          (Zot tiene su propia htpasswd;
                                           OCI clients no hablan OAuth.)
```

Componentes:

- **Caddy** (TLS edge) hace `forward_auth` a oauth2-proxy en todos los
  vhosts operator-facing.
- **oauth2-proxy** (`quay.io/oauth2-proxy/oauth2-proxy:v7.7.1`)
  intercambia con GitHub, valida la identidad del usuario contra una
  doble allowlist (email file + membresía de org), y emite una cookie
  HttpOnly de dominio `.platform.fmd.fagorhealthcare.com`.
- **Cookie scope** `.platform.fmd...` significa que **un solo login
  vale para los 4 subdominios**. SSO transparente.

Excepciones intencionadas que **no** pasan por oauth2-proxy:

1. **`/loki/api/v1/push`** — el endpoint donde Vector publica logs
   desde el cluster. Vector habla basic auth, no OAuth. Esa ruta
   conserva `basic_auth` con credenciales del fichero
   `platform-credentials.txt`.
2. **`registry.platform...` (Zot)** — los clientes Docker/OCI hablan
   HTTP basic via WWW-Authenticate. Si pones oauth2-proxy delante,
   `docker pull` deja de funcionar. **Desde 2026-05** Zot gestiona su
   propia auth dual: navegadores via Dex (OIDC), OCI clients via API
   keys generadas desde la UI tras el primer login. Ver sección
   ["Zot authentication"](#zot-authentication) más abajo.
3. **`dex.platform...` (Dex)** — Dex *es* la auth, ponerle gate delante
   sería circular. Caddy es un reverse proxy transparente.
4. **`/healthz`** en el apex — endpoint trivial para monitores de
   uptime externos. Devuelve `200 ok` sin auth.
5. **`/oauth2/*`** — el propio flujo de login (start, callback,
   sign_in, sign_out) debe ser público para que la ronda con GitHub
   funcione.

## Por qué GitHub (y no Microsoft/Google) — provisional

Fagor Healthcare aún no ha confirmado su IdP corporativo (Microsoft
Entra ID, Google Workspace u otro). GitHub se eligió como provider
**interino** porque:

- **Cada operador ya tiene cuenta** (gailen, fagorhealthcare,
  externos). Cero alta de usuarios nuevos.
- **MFA viene heredado** del propio GitHub.
- **Migrar a Microsoft o Google son ~3 flags** en el container
  `oauth2-proxy`. Ningún otro componente del stack toca identidad
  (Caddy sólo hace `forward_auth`; los servicios detrás reciben
  cabeceras estándar `X-Auth-Request-Email`/`X-Auth-Request-User`).
  Decisión reversible y barata.
- **Defensa en profundidad**: además del email allowlist, el
  container está configurado con `--github-org=FagorHealthcare` —
  sólo miembros de esa org pasan, aunque su email esté en
  `emails.txt`.

Pieza coste: cuando Fagor confirme provider, hay que (a) registrar
una nueva App en su tenant, (b) cambiar 3 flags en
`docker-compose.yml`, (c) refrescar las sesiones (`docker compose
restart oauth2-proxy`). Sin downtime de los servicios detrás.

## Cómo añadir un operador

Tres pasos. Tarda ~30 segundos:

1. **Editar la allowlist**. Añadir el email verificado del usuario
   en `platform/oauth2-proxy/emails.txt` (una línea por persona). El
   email debe ser el **primary** o **verified** en su cuenta de
   GitHub. Si tiene "Keep my email addresses private" activado,
   GitHub envía a oauth2-proxy un alias `<id>+<user>@users.noreply.
   github.com`; el allowlist tiene que incluir ese alias.

   ```diff
    jorge.uriarte@gailen.es
   +nueva.operadora@fagorhealthcare.com
   ```

2. **Verificar la membresía en la org `FagorHealthcare`**.

   ```
   https://github.com/orgs/FagorHealthcare/people
   ```

   Si no aparece, **enviarle invitación**. Sin la membresía a la org,
   el `--github-org` flag bloquea su sesión incluso con el email en
   la allowlist.

3. **Traer el nuevo `emails.txt`** al droplet. oauth2-proxy ya tiene
   un watcher de fsnotify activo sobre el fichero (lo dice en su log
   de arranque: `watching '/etc/oauth2-proxy/emails.txt' for updates`)
   y recarga automáticamente en cuanto el fichero cambia en disco.
   No hace falta restart ni señal:

   ```bash
   ssh root@platform.fmd.fagorhealthcare.com
   cd /opt/platform/stack
   git pull --ff-only
   ```

   Las sesiones activas NO se ven afectadas.

   > **NO uses `docker compose kill -s HUP oauth2-proxy`.** oauth2-proxy
   > v7+ trata SIGHUP como shutdown graceful, no como reload. El
   > container termina y hay que volver a levantarlo con
   > `docker compose up -d oauth2-proxy`. El watcher de fsnotify es el
   > único mecanismo soportado de recarga. (Aprendido en el despliegue
   > inicial 2026-05-18.)

## Cómo quitar un operador

Mismos 3 pasos pero quitando la línea (o comentándola con `# `). El
HUP invalida la cache en memoria pero **NO invalida las sesiones ya
emitidas**: las cookies seguirán siendo válidas hasta su expiry
(168h = 7 días por defecto, configurado en `--cookie-expire`).

Si necesitas **expulsión inmediata** del usuario (compromiso de
credencial, salida abrupta):

```bash
# Rotar el cookie secret — invalida TODAS las sesiones, todos vuelven a
# loguearse. Cinco segundos de molestia colectiva.
ssh root@platform.fmd.fagorhealthcare.com
NEW_SECRET=$(openssl rand -base64 32)
sed -i "s|^OAUTH2_COOKIE_SECRET=.*|OAUTH2_COOKIE_SECRET='$NEW_SECRET'|" /opt/platform/.env
docker compose up -d oauth2-proxy   # recreate, no restart (env change)
```

## Cómo entra un usuario nuevo por primera vez

Flujo desde el punto de vista del operador:

1. Abre `https://platform.fmd.fagorhealthcare.com/`.
2. Caddy ve que no hay cookie de sesión → redirige a `/oauth2/start`.
3. oauth2-proxy redirige a GitHub para autorizar la App `FMD
   Platform Observability` con scopes `read:user user:email`.
   **Primera vez**: GitHub pide consentimiento explícito.
4. Tras OK, GitHub devuelve a `/oauth2/callback` con un code.
5. oauth2-proxy intercambia el code por un token, lee el email del
   user, comprueba (a) que está en `emails.txt`, (b) que es miembro
   de `FagorHealthcare`. Si pasa, emite cookie y redirige al landing.
6. A partir de aquí, los 4 subdominios funcionan sin re-login durante
   168h.

Si falla (no autorizado): oauth2-proxy renderiza una página
"Permission Denied" con el email que recibió. Para diagnosticar:

```bash
docker compose logs oauth2-proxy --tail=50
```

## Solución de problemas

### Página de login no responde / loop infinito de redirects

Casi siempre es **cookie domain mismatch**. La cookie está atada a
`.platform.fmd.fagorhealthcare.com` (nota el punto inicial). Si
accedes vía la IP cruda o un alias DNS distinto, el navegador no la
manda. Comprueba la URL.

### "403 Forbidden — Permission Denied"

oauth2-proxy detalla la razón en logs (`docker compose logs
oauth2-proxy`). Tres posibilidades:

- Email no en `emails.txt`.
- Usuario no es miembro de la org `FagorHealthcare`.
- Email "private" en GitHub y no concediste el scope `user:email`
  (raro — el flag `--scope` ya lo pide).

### Vector deja de empujar logs

Verifica que sigues hablando con `/loki/api/v1/push`. Esa ruta tiene
**su propia regla `basic_auth`** en el Caddyfile (matcher
`@vector_push`) que esquiva oauth2-proxy. Si los logs llegan a Loki
pero NO los webhooks de alerta, mira a `alertmanager` (otra ruta).

### "Cookie secret must be 16, 24, or 32 bytes"

`OAUTH2_COOKIE_SECRET` en `.env` no se generó bien. Regenerar:

```bash
openssl rand -base64 32 > /tmp/c
sed -i "s|^OAUTH2_COOKIE_SECRET=.*|OAUTH2_COOKIE_SECRET='$(cat /tmp/c)'|" /opt/platform/.env
rm /tmp/c
docker compose up -d oauth2-proxy
```

### Logs de Loki sin tu identidad

`forward_auth` añade cabeceras `X-Auth-Request-Email` y
`X-Auth-Request-User` al request que llega a Loki, pero Loki las
ignora — no las propaga al log de queries. Para auditar "quién
consultó qué" hay que mirar los logs de Caddy (en stdout, JSON
formato), filtrando por `host:logs.platform...` + path
`/loki/api/v1/query*`.

## Zot authentication

Zot (la registry) tiene un modelo de auth **dual** distinto al resto del
stack, porque ahí conviven dos tipos de cliente:

```
Browser (operador) ─► Caddy ─► Zot ─OIDC redirect─► Dex ─OAuth─► GitHub
                                 ▲                    │
                                 │                    │ (FagorHealthcare org check)
                                 │                    │
                                 └──── id_token ─────┘
                                       + groups claim

docker / oras / kubelet ─► Caddy ─► Zot (HTTP basic: user + API key)
```

### Por qué dos mecanismos

- Los clientes OCI (docker pull, oras push, kubelet con pull secret, CI
  runners) hablan **HTTP basic via WWW-Authenticate**. No saben hacer
  redirecciones OAuth ni guardar cookies. Forzarles OIDC rompe `docker
  pull` el primer día.
- Los humanos quieren SSO con su cuenta de GitHub, sin gestionar otra
  contraseña. Y queremos que el grupo de GitHub controle quién puede
  push/pull a cada repo.
- Zot soporta los dos a la vez (`http.auth.openid` + `http.auth.apikey`
  en `config.json`). Los humanos generan sus propias API keys desde la
  UI tras el primer login; esas keys son lo que va al pull-secret del
  cluster y a los GitHub Actions secrets.

### Componentes

- **Dex** (`dexidp/dex:v2.41.1`) corre como broker OIDC en
  `dex.platform.fmd.fagorhealthcare.com`. Frente a Zot expone un issuer
  estándar OIDC; por detrás habla con GitHub. Persiste refresh tokens y
  signing keys en sqlite (volumen `dex_data`) para no rotar las claves
  en cada restart.
- **App de GitHub OAuth "FMD Dex"** — DISTINTA de "FMD Platform
  Observability" que usa oauth2-proxy. Las dos pueden coexistir en la
  org `FagorHealthcare`. Callback de "FMD Dex":
  `https://dex.platform.fmd.fagorhealthcare.com/callback`.
- **Zot** (config en `platform/zot/config.json.tmpl`) declara `oidc`
  como provider de OpenID y `apikey: true`. El `credentialsFile`
  (rendered desde `platform/zot/oidc-credentials.json.tmpl`) contiene
  el secret compartido con el `staticClient` de Dex.

### accessControl en Zot — qué pasa cuando el JWT trae `groups`

Dex pide a GitHub el scope `read:org` y emite en el id_token un claim
`groups` con la forma `["FagorHealthcare:<team-slug>", ...]` (porque
`teamNameField: slug` en la config de Dex). Zot lee ese claim y lo
mapea **directamente** a su modelo de groups en `accessControl.repositories.**.policies`.
No hay un mapeo intermedio en `accessControl.groups` — el string del
claim se compara literal contra el campo `groups` de la policy.

Por eso `.env` tiene dos variables que el operador rellena:

```
ZOT_RW_GROUP=FagorHealthcare:<slug-del-team-RW>     # ej. platform
ZOT_RO_GROUP=FagorHealthcare:<slug-del-team-RO>     # ej. cluster-pull
```

Listar slugs reales de la org:

```bash
gh api orgs/FagorHealthcare/teams --jq '.[] | .slug'
```

### Cómo registrar la OAuth App "FMD Dex" (paso manual, una vez)

1. `https://github.com/organizations/FagorHealthcare/settings/applications/new`
2. Datos:
   - **Application name**: `FMD Dex`
   - **Homepage URL**: `https://dex.platform.fmd.fagorhealthcare.com`
   - **Authorization callback URL**:
     `https://dex.platform.fmd.fagorhealthcare.com/callback`
3. Tras "Register application", generar un client secret.
4. Apuntar Client ID + Client Secret en
   `/opt/platform/.env` del droplet como:
   ```
   DEX_GITHUB_CLIENT_ID=...
   DEX_GITHUB_CLIENT_SECRET=...
   ```
5. `DEX_ZOT_CLIENT_SECRET` ya lo generó cloud-init
   (`openssl rand -hex 32`) y está en `/root/platform-credentials.txt`.
6. `docker compose up -d --force-recreate dex zot` para que ambos
   relean el `.env`.

### Generar la primera API key (bootstrap del CI)

Tras el primer despliegue, las API keys aún no existen. El procedimiento:

1. Loguéate como humano en `https://registry.platform.fmd.fagorhealthcare.com/`
   y pasa por el flujo Dex→GitHub.
2. En la UI de Zot, panel del usuario → **API Keys** → **Create new**.
   Dale un label descriptivo (`ci-md-core`, `kubelet-pull`, etc).
3. Copia la key inmediatamente — Zot solo la muestra una vez.
4. Para CI: añade la key como GitHub Actions secret en el repo
   correspondiente. Reemplaza el hardcoded `gailen:873e27e5-…` de
   `add_tag.sh` por una llamada con esta credencial (PR de
   seguimiento, uno por servicio).
5. Para el cluster: regenera el pull-secret con la key. Una sola key
   "kubelet-pull" basta para todos los Deployments siempre que el
   `imagePullSecrets` apunte a ese secret.

### Solución de problemas (Zot+Dex)

**Zot no arranca, log dice "openid provider not reachable"** — Dex no
está respondiendo en su issuer. Mira `docker compose logs dex`.
Causas típicas: variables `DEX_*` vacías (Dex no arranca), DNS de
`dex.platform.fmd...` no propagado todavía, o el cert de Caddy aún
no emitido (la primera vez tarda ~30 s con HTTP-01). El `depends_on:
dex: { condition: service_healthy }` debería evitar la carrera, pero
si Dex está mal configurado nunca llega a healthy.

**Login redirige a GitHub y vuelve con "user is not a member of the
required organization"** — Dex está aplicando el `orgs:
FagorHealthcare` check. Verifica que el usuario es miembro **público
o privado** de la org en `https://github.com/orgs/FagorHealthcare/people`.
Si está pero como invitado, hay que confirmar la invitación.

**Login OK, pero al hacer `docker pull` salen 403** — Zot recibió el
token, pero el claim `groups` no contenía ni `ZOT_RW_GROUP` ni
`ZOT_RO_GROUP`. Lista los teams del user:

```bash
gh api orgs/FagorHealthcare/teams --jq '.[] | .slug'
gh api /user/teams --jq '.[] | "\(.organization.login):\(.slug)"'
```

Asegúrate de que el slug exacto coincide con lo que hay en `.env`.

**API key dejó de funcionar** — Zot guarda las keys vinculadas al
usuario que las creó. Si ese usuario sale de la org en GitHub, su
sesión OIDC deja de validar y sus API keys quedan huérfanas. Solución:
re-emitirlas con otro usuario antes de revocar la membresía.

## Plan de migración al IdP corporativo

Cuando Fagor confirme provider, los pasos son:

### Microsoft Entra ID (Azure AD)

1. Fagor IT registra una App en su tenant (`portal.azure.com` → App
   registrations). Datos necesarios:
   - Name: "FMD Platform Observability"
   - Redirect URI (web): `https://platform.fmd.fagorhealthcare.com/oauth2/callback`
   - Permissions: `User.Read`, `email`, `profile`, `openid`
2. Obtienen Client ID, Client Secret, Tenant ID.
3. Cambias en `docker-compose.yml` (servicio `oauth2-proxy`):
   ```diff
   - - --provider=github
   - - --github-org=FagorHealthcare
   + - --provider=oidc
   + - --oidc-issuer-url=https://login.microsoftonline.com/<TENANT_ID>/v2.0
   ```
4. Cambias `.env`: `OAUTH2_CLIENT_ID` y `OAUTH2_CLIENT_SECRET` con
   los nuevos.
5. `docker compose up -d oauth2-proxy`.
6. Las sesiones vivas siguen siendo válidas — el provider sólo se
   consulta al crear sesión nueva. Cuando expiren (o quites el cookie
   secret) los usuarios entran ya por Microsoft.

El allowlist `emails.txt` sigue funcionando igual con el provider
oidc: el email del token JWT se valida contra el fichero.

### Google Workspace

Mismo patrón pero más simple:

```diff
- - --provider=github
- - --github-org=FagorHealthcare
+ - --provider=google
```

Y registras una OAuth Client en Google Cloud Console del workspace.

## Decisiones tomadas y por qué (referencia rápida)

| Decisión | Por qué |
|---|---|
| GitHub como provider inicial | Cada operador ya tiene cuenta; IdP corporativo de Fagor sin confirmar |
| Allowlist por email file (no por dominio) | Más granular; permite externos sin conceder acceso a todo `@fagorhealthcare.com` |
| Doble check: email + github-org | Defensa en profundidad; si email allowlist tiene un typo, la org filtra |
| Cookie domain `.platform.fmd.*` | SSO entre 4 subdominios sin re-login |
| `cookie-expire=168h` (1 semana) | Trade-off entre UX (no relogueo constante) y seguridad (sesión no eterna) |
| Vector y Zot fuera de OAuth | Clientes no-browser no hablan OAuth; cambio sería destructivo |
| `--reverse-proxy=true` + `--whitelist-domain=.platform.fmd.*` | Caddy es trusted; redirecciones controladas a nuestro dominio |
| Estilo visual del portal apex copiado de `md-resi-front/src/status.html` | Continuidad con el otro punto de salud que ya existía en el sistema |

## Pendientes conocidos

- **Audit en Loki**: hoy los logs de quién consultó qué viven en el
  log de Caddy. Sería más limpio empujar los `X-Auth-Request-Email`
  a un campo estructurado y agregarlo en Loki. Pendiente para
  cuando el volumen lo justifique.
- **Status del MCP**: cuando se implemente el servidor MCP de
  observabilidad (`docs/observability-mcp-DESIGN.md`), será otro
  consumer detrás de oauth2-proxy. El header `X-Auth-Request-Email`
  ya está siendo propagado por `copy_headers` para ese uso.
- **Sesiones persistentes**: oauth2-proxy guarda sesiones en
  cookie firmada, no en Redis. Bien para 1 instancia; si algún día
  escalamos horizontalmente, hay que añadir Redis al stack.
