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

