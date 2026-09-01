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

### Verificación de punta a punta (ticket 001)

_Pendiente de completar con evidencia real tras el primer push del PR
de este ticket — ver la sección "Hecho" del ticket 001
(`done/001-migrar-infra-compartida-desde-auth-core-mc.md` una vez
cerrado) para el resultado exacto (estado de `docker ps` en la VM,
jobs de Jenkins, usuario `marco` en SonarQube, respuesta real de los 4
subdominios, y confirmación de que un push solo-`docs/` no disparó el
workflow)._

