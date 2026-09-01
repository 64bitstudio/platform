# 001 — Migrar la infra compartida de la VM desde `auth-core-mc`

## Objetivo
Sacar de `auth-core-mc/deploy/vm-infra/*` todo lo que es infra
COMPARTIDA de la VM (no específica de ese proyecto) y traerlo a este
repo — corrigiendo el error de estructura señalado explícitamente por
Marco (2026-08-31): esa infra quedó construida dentro del repo de un
proyecto, cuando en realidad cada core es solo un consumidor de ella.
Ver memoria del equipo `saas-paas-cores-strategy` para el contexto
completo de esta decisión, y `auth-core-mc/docs/ARQUITECTURA.md`
(tickets 049/050) para la historia técnica de cómo se construyó cada
pieza — no se repite aquí, solo se referencia.

**Riesgo real que motiva este ticket, ya identificado**: si
`mail-core-mc` (ticket gemelo 011, sin empezar) copiara el patrón
actual tal cual, duplicaría el job `sync-vm-infra` completo dentro de
su propio `ci.yml` — exactamente la redundancia que Marco pidió evitar.

**Postura de riesgo (aclarada explícitamente por Marco, 2026-08-31):
nada está operando de cara a clientes reales todavía** — no tratar esta
migración con cautela de "downtime de producción". Sí seguir siendo
correctos y verificar cada paso, pero sin la ceremonia de ventana de
mantenimiento que se aplicó al ticket 049/050.

## Alcance

**Incluye — mover a este repo:**
- `deploy/vm-infra/traefik/` (Traefik + su config).
- `deploy/vm-infra/sonarqube/` (SonarQube + Postgres propia).
- `deploy/vm-infra/jenkins/` (Jenkins + JCasC + Dockerfile — el
  contenedor y su infra, NO el `Jenkinsfile` de cada core, que se
  queda en cada core).
- `deploy/vm-infra/portainer/` (nuevo, ticket 050 de auth-core-mc).
- `deploy/vm-infra/nginx/` — **solo los vhosts de infra compartida**
  (`jenkins.conf`, `vm-admin-tools.conf`). `auth-core-mc.conf` (y el
  futuro `mail-core-mc.conf`) se quedan en cada core respectivo — son
  específicos de ese proyecto.
- El job `sync-vm-infra` de `.github/workflows/ci.yml` de
  `auth-core-mc` — se recrea aquí como el único lugar que lo ejecuta,
  con **path filters que excluyan `docs/**`** (para cumplir la regla
  de "docs nunca disparan CI/CD" de este mismo repo).
- La documentación técnica correspondiente (nueva, en
  `docs/ARQUITECTURA.md` de este repo — no se copia/pega la de
  `auth-core-mc`, se escribe describiendo el estado post-migración).

**No incluye:**
- El `Jenkinsfile` de `auth-core-mc` ni sus
  `docker-compose.{dev,qa,prod}.yml` — son específicos de ese core, se
  quedan donde están.
- Migrar los datos ya existentes de Jenkins/SonarQube/Portainer/Traefik
  en la VM — sus volúmenes de Docker no se tocan, solo cambia DESDE
  QUÉ REPO se define/sincroniza su configuración. Verificar que el
  primer push desde este repo no los recree desde cero perdiendo
  estado (Jenkins ya tiene jobs configurados, SonarQube ya tiene el
  usuario `marco`, etc.).
- El resize de la VM ni Vault (`docs/definiciones/
  vault-secrets-manager-vm.md`, todavía en `auth-core-mc`, pendiente de
  VoBo) — ese documento se mueve a este repo como parte de este
  ticket (ya no aplica el error de ubicación), pero su implementación
  real es un ticket aparte, después de que este cierre.
- Migrar `mail-core-mc` — no existe todavía.

## Pendiente de una acción directa de Marco
- Actualizar la fuente (`docker compose -f ...`) que corre en la VM
  para que el runner de GitHub Actions apunte al checkout de ESTE repo
  en vez de `auth-core-mc` para los pasos de infra compartida — el
  agente debe dejar el comando exacto, probablemente bloqueado para él
  por el mismo clasificador del harness que ya conocemos de sesiones
  anteriores.

## Criterios de aceptación
- Dado un push a este repo (rama principal), cuando corre su CI,
  entonces Traefik/SonarQube/Jenkins/Portainer/nginx quedan
  sincronizados igual que hoy lo hace `sync-vm-infra` en
  `auth-core-mc` — verificado de punta a punta (curl real a los
  subdominios existentes, no solo que el job no truene).
- Dado el mismo push, si SOLO cambia algo en `docs/`, entonces el CI
  de infra NO se dispara (path filter real, verificado).
- Dado que `auth-core-mc` ya no tiene el job `sync-vm-infra`, entonces
  su `ci.yml` se retira por completo (ya no le queda ningún job) o
  documenta explícitamente que la infra compartida ahora vive en
  `platform`.
- Dado el job de Jenkins tipo "GitHub Organization" en
  `64bitstudio`, cuando termine este ticket, entonces sigue
  descubriendo `auth-core-mc` (y `mail-core-mc` a futuro) sin cambios —
  este ticket no debe romper el pipeline de aplicación de ningún core.
