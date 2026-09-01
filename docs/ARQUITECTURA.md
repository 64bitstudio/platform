# Arquitectura — platform

Documentación general de arquitectura/estrategia de 64bitstudio que no
pertenece a un solo core. La historia técnica detallada de cómo se
construyó cada pieza de infra (Jenkins, Traefik, SonarQube, Portainer)
antes de migrar aquí vive en `auth-core-mc/docs/ARQUITECTURA.md`,
tickets 049/050 — no se reescribe esa historia, este documento describe
el estado *actual* post-migración conforme avanza el ticket 001.

## Visión general
Ver memoria del equipo `saas-paas-cores-strategy`: 64bitstudio
construye "cores" reusables (auth-core, mail-core, futuros) sobre
infraestructura 100% gratuita (OCI Always Free), con doble modelo de
negocio — SaaS gestionado por Marco y PaaS/white-label para que un
tercero autoaloje la plataforma en su propia infra. Consecuencia de
diseño: los cores y esta infra compartida deben evitar supuestos
hardcodeados de la infra específica de Marco donde sea razonable.

## Estado actual (post-migración, ticket 001)

Este repo aloja, desde el ticket 001, toda la infra compartida de la VM
(`ssh ampere-free`, OCI Ampere A1) que antes vivía dentro de
`auth-core-mc/deploy/vm-infra/*` — el error de estructura que motivó
este ticket. **Los volúmenes de Docker (datos reales de Jenkins,
SonarQube, Portainer) no se tocaron** — este ticket solo cambió DESDE
QUÉ REPO se sincroniza su configuración; verificado de punta a punta
(ver abajo).

### Qué vive aquí

| Pieza | Ruta | Qué hace |
|---|---|---|
| Traefik | `deploy/vm-infra/traefik/` | Ingress compartido, puertas adentro (`127.0.0.1:8000`) — nginx (fuera de este repo, config de sistema en la VM) es la puerta pública real. |
| SonarQube | `deploy/vm-infra/sonarqube/` | Análisis de calidad compartido por todos los cores + su Postgres propia. Bind interno `127.0.0.1:9000` (Jenkins/runner) + labels de Traefik para `sonarqube.64bitstudio.com` (público, detrás de Basic Auth). |
| Jenkins | `deploy/vm-infra/jenkins/` | Orquestador de build+test+deploy de cada core (vía el `Jenkinsfile` propio de cada core, que NO vive aquí). JCasC + Dockerfile del contenedor. |
| Portainer | `deploy/vm-infra/portainer/` | Dashboard de Docker/Compose de toda la VM, expuesto en `portainer.64bitstudio.com` (Basic Auth). |
| nginx (vhosts compartidos) | `deploy/vm-infra/nginx/{jenkins.conf,vm-admin-tools.conf}` | `jenkins.conf` → `jenkins.64bitstudio.com`. `vm-admin-tools.conf` → los 3 subdominios de infra privilegiada (SonarQube/Traefik dashboard/Portainer), con `auth_basic`. |
| CI | `.github/workflows/ci.yml`, job `sync-vm-infra` | Recreado de `auth-core-mc` (tickets 049/050 de ese repo) — mismo runner self-hosted `vm-oci` (registrado a nivel de ORGANIZACIÓN `64bitstudio`, `enabled_repositories: all`, runner group "Default" visibility "all" — confirmado vía API que corre en `platform` sin registro adicional). Se dispara en push a cualquier rama, **excepto si el push solo toca `docs/**`** (`paths-ignore`, regla de este repo). |

### Qué NO vive aquí (queda en cada core, a propósito)

- `deploy/vm-infra/nginx/auth-core-mc.conf` (y el futuro `mail-core-mc.conf`) — vhost específico de cada core, se queda en su propio repo.
- El certificado Let's Encrypt de `auth.64bitstudio.com`/`auth-qa`/`auth-dev` — específico de ese core, nunca se pidió desde este repo.
- El `Jenkinsfile` y los `docker-compose.{dev,qa,prod}.yml` de cada core — despliegan la APP de ese core, no infra compartida.

### Consecuencia real, documentada (no un descuido)

Al retirar el `ci.yml` completo de `auth-core-mc` (ya no le quedaba
ningún job tras sacar `sync-vm-infra`), el vhost `auth-core-mc.conf` y
su certificado quedaron **sin ningún job que los vuelva a aplicar** si
cambiaran o si la VM se reconstruyera desde cero. La renovación
automática del certificado SÍ sigue funcionando (`certbot.timer` del
sistema, verificado activo y con un `certbot renew --dry-run` real en
verde en la VM — no depende de GitHub Actions). Si `auth-core-mc.conf`
necesita cambiar en el futuro, hace falta decidir un mecanismo nuevo
(reintroducir un paso similar a este, o moverlo al `Jenkinsfile` de ese
core) — fuera de alcance de este ticket, señalado aquí a propósito.

### Verificación de punta a punta (ticket 001, 2026-09-01)

Primer push real del PR #1 de este repo (commit `d1bcf0d`) disparó
`sync-vm-infra` en el runner `vm-oci` (run
[33461606741](https://github.com/64bitstudio/platform/actions/runs/33461606741)) — 18/18 steps en verde, incluida la notificación de éxito a
Telegram. Verificado con evidencia real, no solo "el job pasó":

- **Hallazgo real (esperado, no un bug)**: Traefik y Jenkins SÍ se
  recrearon (contenedores nuevos) en este primer push — confirmado con
  `docker inspect --format '{{.State.StartedAt}}'`. Causa: sus
  `docker-compose.yml` bind-montan archivos por **ruta relativa**
  (`./config/traefik.yml`, `./casc`), y Docker Compose resuelve eso a
  la ruta ABSOLUTA del checkout en el runner — que cambió de
  `.../_work/auth-core-mc/auth-core-mc/...` a
  `.../_work/platform/platform/...` al migrar de repo. Compose ve un
  "config distinto" y recrea el contenedor, aunque el contenido del
  archivo sea idéntico. **Sin pérdida de datos**: Traefik no tiene
  estado (proxy puro). Jenkins guarda todo en el volumen NOMBRADO
  `vm-infra-jenkins_jenkins_home` (`docker volume inspect` confirma
  `CreatedAt: 2026-08-30T23:40:49Z`, de ANTES de este ticket, sin
  tocar) — la recreación del contenedor no toca ese volumen.
  SonarQube y Portainer NO se recrearon (`docker ps` con timestamps de
  antes de este push) porque sus compose no bind-montan nada dentro
  del checkout del repo, solo volúmenes nombrados / `docker.sock`.
- **Jenkins conserva sus jobs**: `docker exec jenkins ls
  /var/jenkins_home/jobs/64bitstudio/jobs/` muestra `auth-core-mc`
  intacto — el job tipo "GitHub Organization" nunca se perdió.
- **SonarQube conserva el usuario `marco`**: consulta SQL directa a
  `sonarqube-db` (`select login, active from users where
  login='marco'`) → `marco | t`, con `created_at` de antes de este
  ticket.
- **Los 4 subdominios responden con el backend real** (verificado
  vía Traefik local en la VM, sin pasar por Basic Auth de nginx, para
  confirmar que el upstream real está vivo, no solo que nginx devuelve
  401): `sonarqube.64bitstudio.com` → `200`, `portainer.64bitstudio.com`
  → `200`, `traefik.64bitstudio.com` → `302` (redirect a `/dashboard/`,
  esperado), `jenkins.64bitstudio.com` → `403` (propia seguridad de
  Jenkins para anónimos, esperado). Sin líneas `502`/`504` en el error
  log de nginx. TLS real de Let's Encrypt vigente en los 4 (`notAfter`
  entre 28 y 29 de noviembre de 2026) más `auth.64bitstudio.com`
  (core-specific, sin cambios, TLS igual de vigente).
- **`paths-ignore: ['docs/**']` funciona de verdad**: un segundo push
  al mismo PR que solo tocó este archivo (`docs/ARQUITECTURA.md`,
  commit `86f5a90`) generó **cero check-runs** en GitHub (`gh api
  .../commits/86f5a90/check-runs` → `total_count: 0`) — el workflow no
  se disparó, a diferencia del push anterior con cambios reales.

### Hallazgo real (2026-09-01): recrear Jenkins mató un build en curso de otro repo

Mientras este primer push corría `sync-vm-infra` (02:11:26–02:12:02),
había un build de Jenkins EN CURSO para el PR #82 de `auth-core-mc`
(gradle `build sonar`, iniciado 02:09:52). El paso "Jenkins (orquestador
del pipeline...)" recreó el contenedor `jenkins` a las 02:11:53 — no por
un cambio real de `Dockerfile`/`plugins.txt` (el hash-check ya cubre
eso), sino porque el bind mount `deploy/vm-infra/jenkins/casc/` se
resuelve a la ruta ABSOLUTA del checkout en el runner
(`/home/ubuntu/actions-runner-64bitstudio/_work/<repo>/<repo>/...`), y
esa ruta cambió al venir de `platform` en vez de `auth-core-mc` —
Docker Compose vio un "config distinto" y recreó el contenedor pese a
que el contenido del archivo es idéntico. El build de gradle en curso
(proceso dentro del contenedor viejo) murió con el contenedor; Jenkins
volvió a subir a los 30s, pero el *durable task* que corría el shell
del pipeline ya no existía — el build #1 de ese PR falló 10 minutos
después con `FAILURE` (timeout del heartbeat), sin ningún error real de
compilación/tests (confirmado: 0 ocurrencias de `FAILED`/
`AssertionError`/`Compilation failed` en su log). Se resolvió
reintentando ese build (push de un commit vacío en `auth-core-mc`, build
#2) — no fue necesario tocar nada de este repo.

**Esto era una migración de una sola vez para esta ruta específica**
(la ruta del checkout de `platform` ya queda fija de aquí en adelante,
así que un push futuro normal a `platform` no debería volver a recrear
Jenkins por este mismo motivo) — pero el riesgo de fondo es real y
general, no exclusivo de esta migración: **cualquier cosa que recree el
contenedor de Jenkins (cambio de `Dockerfile`/`plugins.txt`, de GID, de
`casc/`, etc.) puede matar un build de cualquier core que esté corriendo
en ese instante**, porque `sync-vm-infra` y el pipeline de cada core
(`Jenkinsfile`) corren sin ninguna coordinación entre sí. Propuesto como
mejora futura (no implementado en este ticket, fuera de su alcance):
que el paso que recrea Jenkins en `sync-vm-infra` primero verifique si
hay un build activo (`docker exec jenkins ...` contra la API de Jenkins,
o un lock simple en la VM) y lo espere/reintente en vez de recrear a
ciegas — candidato a hook/chequeo nuevo, mismo criterio que
`docker-preflight.sh` para el gotcha de OrbStack.

## Ticket 002 (2026-09-01): infra endurecida + runbook de proyecto nuevo

Cierra el hallazgo de arriba y deja mecánico conectar un core nuevo. Ver
`in-process/002-...md` (o `done/` si ya cerró) para el alcance completo
y memoria de equipo `saas-paas-cores-strategy`.

### 1. Recreate seguro de Jenkins -- resuelto y verificado en vivo

Nuevo paso en `ci.yml`, **antes** de cualquier `docker compose ... up`
de Jenkins: "Esperar si Jenkins tiene un paso 'sh' activo antes de
recrearlo".

**Iteración real del mecanismo** (dos intentos, el primero estaba mal):
1. Primer intento: leer `<result>` en el `build.xml` de cada build,
   asumiendo que solo aparece al terminar. **Falso** -- en esta versión
   de Jenkins aparece desde el primer instante del build (default
   `SUCCESS`), volviendo el chequeo un no-op (verificado: apareció a los
   36s de iniciado un build que tardó 165s en terminar de verdad).
2. El mtime del log tampoco alcanza: `./gradlew test` no imprime nada
   mientras corren los tests -- se observaron **108s de silencio real**
   en un build genuino, más que cualquier umbral razonable de "sin
   output reciente".
3. **Mecanismo que sí funciona** (el que quedó): el directorio de
   control que el plugin `durable-task` crea por cada paso `sh` en
   ejecución (`<workspace-o-subdir>@tmp/durable-<id>/`, dentro de
   `jenkins_home`, leído vía `docker exec jenkins find ...`, sin
   necesitar la API HTTP de Jenkins ni credenciales). Confirmado en vivo
   que aparece exacto al iniciar el paso `sh` y desaparece exacto al
   terminar, sin depender de si el comando produce output. No existe
   durante un `input` pausado (gate de prod, hasta 7 días) ni durante
   `waitForQualityGate` -- ninguno de los dos sostiene un proceso real
   que una recreación del contenedor pudiera matar (son estado CPS puro,
   sobreviven un restart de Jenkins), así que correctamente NO bloquean
   la recreación.

**Verificación real, provocada a propósito (2026-09-01, no solo código
revisado)**: se pusheó un cambio real a `auth-core-mc` (invalidando el
cache de Gradle para forzar un build no-cacheado) y, en el instante en
que el paso `./gradlew build sonar` estaba genuinamente ejecutando
(`@tmp/durable-c03f659c` presente), se pusheó *casi simultáneamente* un
cambio real a `platform` que fuerza la recreación de Jenkins (label
nuevo en `docker-compose.yml`, que si el contenedor ya existía con un
config distinto SIEMPRE lo recrea, sin depender de si el `Dockerfile`
cambia). Resultado observado, con timestamps:
- `sync-vm-infra` llegó al paso "Esperar..." y se quedó ahí mientras
  `@tmp/durable-320a7f27` (el paso `sh` del build de `auth-core-mc`)
  seguía presente -- confirmado repetidamente durante ~180s reales,
  incluyendo los 108s silenciosos de `Task :test`.
- El directorio `durable-320a7f27` desapareció a las **03:56:11 UTC**
  (el paso `sh` terminó).
- Jenkins se recreó a las **03:56:15 UTC** -- 4 segundos después, no
  antes.
- El build de `auth-core-mc` (build #4 de esa rama) terminó
  `Finished: SUCCESS` -- **no lo mató**, a diferencia del incidente
  original documentado arriba.

Límite aceptado: si un paso `sh` sigue activo tras 10 minutos de espera,
`sync-vm-infra` procede de todas formas con un `::warning::` explícito
en el log del run (excepción conocida, no un silencio) -- evita que un
build colgado bloquee la infra compartida indefinidamente.

### 2. Resiliencia a reinicio de la VM

Verificado con evidencia real (no asumido):
- `docker inspect --format '{{.HostConfig.RestartPolicy.Name}}'` en los
  4 contenedores (`jenkins`, `traefik`, `sonarqube`, `sonarqube-db`,
  `portainer` -- 5 en realidad, Sonar tiene su propia DB) →
  `unless-stopped` en los 5, consistente con cada `docker-compose.yml`.
- El runner self-hosted corre como servicio systemd
  (`actions.runner.64bitstudio.vm-oci-runner.service`),
  `systemctl is-enabled` → `enabled` (arranca solo al bootear, no algo
  manual).

**Pendiente real, no verificado**: el criterio de aceptación pide
confirmar esto con un reinicio REAL de la VM. El comando (`sudo
reboot`) fue bloqueado por el clasificador de permisos del harness de
Claude Code (acción de infra crítica) -- correcto que lo bloquee, no se
intentó forzar. Si Marco quiere la prueba en vivo (no debería tomar más
de 1-2 min de indisponibilidad total, nada opera de cara a clientes
reales todavía), el comando exacto es:

```
ssh ampere-free "sudo reboot"
# esperar ~60-90s, luego:
ssh ampere-free "docker ps --format '{{.Names}}\t{{.Status}}'; systemctl is-active actions.runner.64bitstudio.vm-oci-runner.service"
```

### 3-4. Shared Library + vhost ya no huérfano

Nueva Shared Library estándar de Jenkins en este mismo repo:
`vars/corePipeline.groovy` (patrón `vars/`, un solo global step
`corePipeline(config)`). Registrada vía JCasC
(`deploy/vm-infra/jenkins/casc/jenkins.yaml`,
`unclassified.globalLibraries`, nombre `"platform"`,
`defaultVersion: "main"`, `implicit: false` -- cada Jenkinsfile la pide
explícito con `@Library('platform') _`).

Cubre exactamente lo que hacía el `Jenkinsfile` viejo de `auth-core-mc`
(build+test+Sonar/Quality Gate/build de imagen/deploy dev-qa-prod/gate
manual de prod/cleanup.sh/notificación a Telegram) más, nuevo, el paso
de vhost de nginx (punto 4 -- ya no depende de un `ci.yml` que no existe
más, corre en la Shared Library en cada deploy a `dev`). Contrato de
`config` documentado en cabecera del archivo. `deploy: false` desactiva
todo lo de imagen/vhost/deploy para un core que todavía no tiene
Dockerfile/deploy real (ver punto 11, `mail-core-mc`). `buildAndTest` es
un `Closure` opcional (obligatorio pasar el propio, distinto por stack)
-- si se omite, la etapa queda como placeholder explícito, nunca oculto.

`auth-core-mc/Jenkinsfile` quedó reducido de ~200 líneas a invocar
`corePipeline(...)` con sus parámetros propios.

**Verificado en vivo** (ver evidencia del punto 1 arriba, mismo build):
la Shared Library cargó correctamente desde Jenkins, el closure
`buildAndTest` (gradle + `withSonarQubeEnv`) corrió sin errores de
sintaxis/CPS, y el build completo (`build+test+Sonar+Quality Gate`)
terminó `SUCCESS` -- probado contra una rama de feature (`branch 'dev'`
gatea las etapas de imagen/vhost/deploy, así que esas NO corrieron en
esa rama, por diseño).

**Pendiente real, no verificado todavía**: las etapas exclusivas de
`dev` (build de imagen, aplicar el vhost, deploy, healthcheck,
`cleanup.sh`) requieren un push real a la rama `dev` de `auth-core-mc`
para ejercitarse -- Jenkins resuelve `branch 'dev'` por el nombre real
de la rama, no hay forma de simularlo desde una rama de feature. Quien
cierre este ticket (mergeando `platform#<PR>` y luego
`auth-core-mc#<PR>` a `dev`) debe verificar, tras ese merge:
1. El build de Jenkins de la rama `dev` de `auth-core-mc` corre las
   etapas "Build de la imagen", "Vhost de nginx (dev)" y "Deploy a DEV"
   en verde.
2. `curl -I https://auth.64bitstudio.com` (o el endpoint que corresponda
   una vez resuelto el hallazgo de abajo) no se interrumpe durante ese
   deploy.

### Hallazgo real, no relacionado con este ticket (2026-09-01): `auth.64bitstudio.com` (PROD) responde 404 ahora mismo

Encontrado al intentar verificar la continuidad de servicio del punto
4. **No lo causó nada de este ticket** -- confirmado con evidencia:

- `curl https://auth.64bitstudio.com/` → `404` (nginx, no una página de
  Spring Boot).
- Mismo resultado pegándole directo a Traefik en la VM con
  `Host: auth.64bitstudio.com` (bypass de nginx) → `404`.
- La API de Traefik (`/api/http/routers`) confirma que **no existe
  ningún router para `auth.64bitstudio.com`** -- solo
  `auth-core-mc-dev`/`auth-core-mc-qa`, ninguno de prod.
- El contenedor `auth-core-mc-prod-app-1` SÍ está `Up` y `healthy`
  (`curl http://localhost:8080/actuator/health` en la VM → `200 UP`),
  pero sus labels reales (`docker inspect ... Config.Labels`) **no
  tienen ningún `traefik.*`** y su única red es
  `auth-core-mc-prod_default` -- NO está conectado a `edge`.
- El `docker-compose.prod.yml` actual del repo SÍ declara los labels de
  Traefik y la red `edge` correctamente -- el contenedor que corre hoy
  es de una versión ANTERIOR del archivo (su label
  `com.docker.compose.project.config_files` todavía apunta a la ruta
  vieja `_work/auth-core-mc/auth-core-mc/...`, de antes de la migración
  del ticket 001) y nunca se ha vuelto a desplegar desde que se agregó
  el wiring de Traefik.

Es decir: el sitio quedó "huérfano" de Traefik desde que se introdujo
el ingress compartido, y nadie lo notó porque PROD no se ha vuelto a
promover desde entonces (el gate de prod es manual, exclusivo de
Marco). **Se arregla solo con el próximo deploy real a PROD** (que
recreará el contenedor con los labels correctos) -- no se tocó nada al
respecto en este ticket (prod está fuera de alcance para mí). Señalado
aquí explícitamente para que Marco lo sepa antes de asumir que
`auth.64bitstudio.com` funciona.

### 5. `chmod` de secrets generalizado

`ci.yml`, paso "Permisos de grupo en los secrets de cada proyecto":
itera `/home/ubuntu/secrets/*/` (todo menos `jenkins/`, que no necesita
acceso de grupo) en vez de hardcodear `auth-core-mc`. Un core nuevo
queda cubierto en cuanto Marco cree su carpeta de secrets, sin tocar
este workflow. Verificado corriendo en `sync-vm-infra` (el paso pasa en
verde con `auth-core-mc/` ya presente).

### 6. Webhook GitHub → Jenkins automático a nivel de organización

**Investigado antes de asumir que hacía falta un script por repo** (tal
como pedía el ticket): sí existe un mecanismo de organización. JCasC
(`unclassified.gitHubPluginConfig`, plugin `github` clásico -- ya
instalado, ver `plugins.txt`) con `manageHooks: true` sobre el mismo
credential `github-pat` que ya usa el Organization Folder. Con esto,
Jenkins crea/mantiene el webhook push de **cualquier** repo que el
Organization Folder descubra -- sin `POST /repos/<owner>/<repo>/hooks`
manual ni por script, nunca más, para ningún core futuro.

**Verificado en vivo**: tras aplicar este cambio (`sync-vm-infra`, PR de
este ticket), el archivo interno de Jenkins
`github-plugin-configuration.xml` confirma `<manageHooks>true</manageHooks>`.
Y, más contundente: al pushear una rama nueva de `auth-core-mc` que YA
tenía webhook (creado a mano antes de este ticket), Jenkins la
descubrió e indexó en menos de 20 segundos -- consistente con que el
mecanismo de hooks sigue vivo tras el cambio.

**Límite real, no resuelto por esto**: para un repo TOTALMENTE nuevo
para Jenkins (nunca escaneado, como `mail-core-mc` -- ver punto 11), el
webhook no puede autocrearse hasta que el Organization Folder lo
descubra por PRIMERA vez, y eso requiere un escaneo (el trigger
periódico corre cada ~4h, `H H/4 * * *`) o un clic manual en Jenkins
("64Bit Studio" → "Scan Organization Folder Now"). No se encontró forma
de disparar ese primer escaneo sin autenticarse en Jenkins (su
seguridad se gestiona 100% por UI desde el ticket 049, sin token de API
disponible para este flujo) -- es la única acción manual real que le
queda al runbook de "proyecto nuevo" (ver más abajo), y ocurre UNA vez
por proyecto nuevo, no en cada push.

### 7. Bootstrap de ramas + branch protection -- automatizado, no manual

`deploy/scripts/bootstrap-project-branches.sh <nombre-del-repo>` --
script idempotente (`gh api` encadenado): crea `dev`/`qa`/`prod` desde
la rama default actual, cambia el default a `dev`, y aplica la misma
branch protection que ya corre en `auth-core-mc` (`required_status_checks`
con `continuous-integration/jenkins/branch`, `required_conversation_resolution`,
sin force-push/deletion). Un solo comando, no una receta de pasos
manuales (ajuste explícito de Marco durante este ticket).

**Verificado en vivo, corrido de verdad contra `mail-core-mc`** (no solo
teoría -- ver punto 11): rama default pasó a `dev`, las 3 ramas existen,
y `gh api repos/64bitstudio/mail-core-mc/branches/dev/protection`
confirma el check requerido y `required_conversation_resolution:true`.

### 8. Runbook: cómo conectar un proyecto nuevo

Con todo lo de arriba, conectar un core nuevo (Jenkinsfile aparte, que
es código de aplicación, no infra) son 3 pasos mecánicos:

1. **Ramas + protección** (un comando, automatizado por completo):
   ```
   ./deploy/scripts/bootstrap-project-branches.sh <nombre-del-repo>
   ```
2. **Jenkinsfile del proyecto**, invocando la Shared Library:
   ```groovy
   @Library('platform') _

   corePipeline(
       projectName: '<nombre-del-repo>',
       healthPorts: [dev: <puerto>, qa: <puerto>, prod: <puerto>],
       vhostFile: 'deploy/vm-infra/nginx/<nombre-del-repo>.conf',  // opcional
       buildAndTest: { /* build+test+Sonar propio del stack */ }    // opcional
   )
   ```
   Si el proyecto todavía no tiene Dockerfile/deploy real, usar
   `deploy: false` y omitir `buildAndTest`/`healthPorts`/`vhostFile`
   (placeholder mínimo, ver `mail-core-mc/Jenkinsfile`).
3. **Descubrimiento por Jenkins** (única acción manual real, una vez por
   proyecto -- ver límite del punto 6): en Jenkins, "64Bit Studio" →
   "Scan Organization Folder Now" (o esperar hasta 4h al trigger
   periódico). A partir de ahí, el webhook se automantiene solo.

El resto (secrets del proyecto en `/home/ubuntu/secrets/<repo>/.env.*`,
permisos de grupo, webhook de SonarQube→Jenkins) ya es 100% automático
vía `sync-vm-infra` (puntos 5 y lo ya existente).

### 10. SonarQube -- retirado de la Mac, con VoBo explícito de Marco

**Hallazgo real, antes de tocar nada**: `docker ps` en la Mac SÍ
mostraba `sonarqube`/`sonarqube-db` corriendo (9+ días de uptime).
Verificado con `psql` directo a esa DB: **tenía historial real de
análisis** -- 102 issues registrados de `auth-core-mc` (desde
2026-08-21) y 8 de `mail-core-mc` (desde 2026-08-26), ambos de ANTES de
que SonarQube se mudara a la VM. Reportado explícitamente antes de
apagar nada (mismo patrón ya documentado en la memoria de equipo
`vm-deploy-infra-roadmap`: Marco ya había decidido NO migrar ese
historial por simplicidad, pero el ticket pedía confirmar antes de
borrar datos reales) -- **Marco confirmó explícitamente**, entonces sí
se corrió `docker compose -f ~/dev-infra/docker-compose.yml down`.
Verificado con evidencia real: `docker ps` ya no lista
`sonarqube`/`sonarqube-db`.

**Efecto colateral real, encontrado y corregido en el momento**: ese
mismo `docker-compose.yml` de `~/dev-infra` también define el
contenedor `vault` (motor Transit local para cifrado por sobres de
`auth-core-mc`, ticket 017 -- ver memoria `saas-paas-cores-strategy`,
"NO extender a producción el Vault que ya existe en `~/dev-infra`").
`docker compose down` sobre el archivo completo paró TODOS sus
servicios, `vault` incluido, no solo SonarQube -- ninguno de los dos
tenía su propio `docker-compose.yml` separado. Corregido de inmediato,
en la misma sesión: `docker compose -f ~/dev-infra/docker-compose.yml
up -d vault` lo volvió a levantar, y como todo contenedor de Vault
queda SELLADO tras cualquier reinicio (comportamiento normal, no un
bug -- ver el comentario de `VAULT_UNSEAL_KEY` en `~/dev-infra/.env`),
se corrió `~/dev-infra/scripts/vault-unseal.sh` para desellarlo --
confirmado con `Sealed: false` en la salida real del comando. Sin
pérdida de datos (el volumen de Vault no se tocó, `docker compose down`
sin `-v`). **Consecuencia a futuro, no resuelta aquí**: si `vault` y
`sonarqube` (este último ya retirado) seguían compartiendo un mismo
`docker-compose.yml` de `~/dev-infra`, cualquier operación futura sobre
ESE archivo (ya solo con Vault adentro) es más simple ahora que
SonarQube salió -- no se separó en un archivo propio en este ticket por
no ser parte de su alcance, señalado aquí por si vale la pena un ticket
chico aparte.

**CLI `sonar` reconfigurado, con límite real descubierto y verificado en
vivo**: el CLI `sonar` (SonarQube CLI v1.6.0, no el `sonar-scanner`
clásico) **no puede combinar Basic Auth de nginx con su propio token**
-- confirmado montando un proxy local de prueba con Basic Auth: el CLI
solo manda `Authorization: Bearer <token>`, nunca además
`Authorization: Basic ...`, e ignora por completo cualquier
`usuario:password@` embebido en la URL del servidor. Como
`sonarqube.64bitstudio.com` está detrás de Basic Auth de nginx (decisión
explícita de Marco, capa extra sobre las 3 herramientas de infra
privilegiada), pegarle directo desde el CLI no es viable.

Solución verificada en vivo (túnel SSH, exactamente como sugería el
ticket): `~/dev-infra/scripts/sonar-vm.sh` -- abre un túnel SSH a
`127.0.0.1:9000` de la VM (mismo puerto interno que ya usa Jenkins,
bypass total de nginx) y corre `sonar` con
`SONARQUBE_CLI_SERVER`/`SONARQUBE_CLI_TOKEN` apuntando ahí. Probado con
un token inválido a propósito: el error viene de SonarQube mismo
(`401` de la API, no de nginx) -- confirma que la conexión SÍ llega
directo al SonarQube real de la VM. `~/dev-infra/.env.example`/`.env`
actualizados: `SONAR_HOST_URL`/`SONAR_TOKEN` viejos marcados
DEPRECADOS (nada los lee ya), nueva variable `SONARQUBE_CLI_TOKEN_VM`
(vacía) -- **pendiente que Marco genere ese token** en
`https://sonarqube.64bitstudio.com` (Administration → Security → Users
→ Tokens, tras pasar el Basic Auth del navegador) y lo pegue en
`~/dev-infra/.env`.

### 11. `mail-core-mc` -- caso de prueba real del runbook

Aplicado el runbook completo (puntos 7-8), solo infra, sin tocar lógica
de negocio (ticket 011 propio de ese repo, sin empezar):
- `dev`/`qa`/`prod` creadas, `dev` como default, branch protection
  aplicada -- vía `bootstrap-project-branches.sh mail-core-mc`,
  verificado con `gh api` real (ver punto 7).
- `Jenkinsfile` mínimo (`chore/002-infra-jenkinsfile-shared-library`,
  PR pendiente): `corePipeline(projectName: 'mail-core-mc', deploy:
  false)` -- sin `buildAndTest` (la imagen de Jenkins no trae Node.js
  ni un scanner de Sonar para JS/TS todavía, y no existen
  Dockerfile/deploy/docker-compose.*.yml/cleanup.sh reales, eso es el
  ticket 011). Cuando ese ticket arranque, este Jenkinsfile se
  actualiza con el `buildAndTest` real y se quita `deploy:false`.
- **Pendiente, acción manual única** (ver límite del punto 6): Jenkins
  todavía no ha escaneado `mail-core-mc` por primera vez (su webhook no
  puede existir hasta entonces) -- falta "Scan Organization Folder Now"
  o el trigger periódico (~4h). Verificado con evidencia real que hoy
  `docker exec jenkins ls jobs/64bitstudio/jobs/` NO incluye
  `mail-core-mc` todavía.

### 12. Hallazgo real (2026-09-01): el vhost y el healthcheck no funcionaban desde el contenedor de Jenkins

Encontrado en el PRIMER deploy real a DEV de `auth-core-mc` tras
mergear los puntos 3/4 (build #8, ver PRs `platform#5`/
`auth-core-mc#83`) -- exactamente el escenario que este ticket pedía
verificar "de punta a punta", y que reveló un supuesto roto al mover
lógica de `ci.yml` (ejecutada DIRECTO sobre el host de la VM por el
runner self-hosted) a la Shared Library (ejecutada DENTRO del
contenedor de Jenkins, `agent any` = el propio controller).

**Bug 1, el que rompió el build**: el stage "Vhost de nginx (dev)"
fallaba con `sudo: not found`. Ni instalar `sudo` habría alcanzado --
seguiría sin ver `/etc/nginx` ni el systemd reales del host (namespaces
distintos). Solución: nueva imagen `platform-host-exec`
(`deploy/vm-infra/jenkins/host-exec/`, alpine + `util-linux`, entrypoint
`nsenter --target 1 --mount --uts --ipc --net --pid --`), lanzada por la
Shared Library vía `docker.sock` (que Jenkins ya monta, mismo modelo de
confianza ya aceptado y documentado en su propio `docker-compose.yml`)
con acceso elevado y PID compartido con el host -- re-ejecuta el
comando dado DENTRO de los namespaces reales de PID 1, así que
`systemctl reload nginx` desde ahí sí recarga el nginx real de la VM,
no uno de un contenedor. Se agregó el build de esta imagen a
`sync-vm-infra`.

**Bug 2, encontrado al revisar el resto del pipeline por el mismo
motivo (no solo el reportado)**: el healthcheck de `deployAndVerify()`
usaba `curl http://localhost:<puerto>` -- ese `localhost` es el
loopback DEL CONTENEDOR DE JENKINS, no del host, nunca iba a alcanzar
el puerto publicado del contenedor de la app. Verificado en vivo:

```
docker exec jenkins curl http://localhost:8081/actuator/health        -> 000
docker exec jenkins curl http://auth-core-mc-dev-app-1:8080/actuator/health -> 200 UP
```

Jenkins y el contenedor de cada app comparten la red `edge` -- se
cambió el healthcheck a pegarle al contenedor por su NOMBRE
(`<project>-<env>-app-1`, determinístico por cómo nombra sus
contenedores Docker Compose) + su puerto INTERNO
(`config.containerPort`, default `8080`, constante entre dev/qa/prod --
reemplaza el `healthPorts` map de puertos publicados al host, que ya no
aplica bajo este mecanismo).

**No se pudo probar el mecanismo elevado de forma aislada vía SSH** --
el clasificador de permisos del harness lo bloqueó al intentarlo
directo desde la terminal (correcto que lo bloquee: es exactamente el
tipo de acción -- lanzar un contenedor con acceso elevado y PID
compartido con el host -- que merece ese filtro; el diseño en sí lo
pidió explícitamente el Product Owner al revisar las opciones reales
disponibles, dado que Jenkins ya tiene `docker.sock` montado). La
verificación real es el siguiente deploy a `dev` con el fix aplicado --
ver PRs `platform#6`/`auth-core-mc#84`.

