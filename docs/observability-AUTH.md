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
   `docker pull` deja de funcionar. Zot mantiene su `htpasswd` propio
   (gestionado por cloud-init).
3. **`/healthz`** en el apex — endpoint trivial para monitores de
   uptime externos. Devuelve `200 ok` sin auth.
4. **`/oauth2/*`** — el propio flujo de login (start, callback,
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

3. **Recargar el proxy** en el droplet. No es un restart, es un
   `SIGHUP` — no rompe sesiones activas:

   ```bash
   ssh root@platform.fmd.fagorhealthcare.com
   cd /opt/platform/stack
   git pull --ff-only
   docker compose kill -s HUP oauth2-proxy
   ```

   El primero (`git pull`) trae el nuevo `emails.txt` al droplet (el
   stack live se sirve desde el repo clonado en cloud-init); el
   segundo le dice a oauth2-proxy "relee el archivo".

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
