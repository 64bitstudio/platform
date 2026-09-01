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
~~Actualizar la fuente que corre en la VM para que el runner apunte al
checkout de este repo~~ — no hizo falta ninguna acción manual: el
runner self-hosted `vm-oci` está registrado a nivel de organización
(`enabled_repositories: all`), así que tomó el checkout de `platform`
solo, sin registro adicional — confirmado en la verificación de punta
a punta de abajo.

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

## Hecho

Cerrado 2026-08-31. `platform` PR #1 (commit `6b8fc2f`) y
`auth-core-mc` PR #82 (commit `b1c3853`), ambos mergeados. Todos los
criterios de aceptación verificados con evidencia real (no solo "el
job pasó"):

- **Datos intactos**: Jenkins conserva el job `64bitstudio/auth-core-mc`;
  SonarQube conserva el usuario `marco`; volumen de Jenkins sin
  recrear desde cero.
- **4 subdominios responden con el backend real** (SonarQube 200,
  Portainer 200, Traefik dashboard 302→`/dashboard/`, Jenkins 403 de
  su propia seguridad), TLS Let's Encrypt vigente en los 4;
  `auth.64bitstudio.com` (específico de `auth-core-mc`) sin afectar.
- **`paths-ignore: ['docs/**']` confirmado 3 veces**: tres pushes
  solo-`docs/` → 0 check-runs, vs. el push con cambios reales que sí
  disparó `sync-vm-infra` (18/18 pasos verdes).
- **14 archivos migrados byte-idénticos** al contenido real de
  `auth-core-mc@dev` antes de la migración.
- `auth-core-mc/.github/workflows/ci.yml` retirado por completo (ya no
  le quedaba ningún job); `docs/ARQUITECTURA.md` de ese repo con nota
  explícita de que la infra compartida se movió aquí, sin borrar la
  historia de los tickets 049/050.

**Hallazgo real, documentado, no bloqueante**: el primer push a este
repo recreó el contenedor de Jenkins (el bind-mount resuelve por ruta
absoluta del checkout, que cambió de repo) mientras un build del PR
gemelo en `auth-core-mc` corría — lo mató por timeout de heartbeat, sin
error real de código (0 fallos de compilación/tests). Se resolvió
reintentando ese build. El riesgo de fondo (recrear Jenkins puede matar
cualquier build concurrente de cualquier core) es real y general — no
resuelto en este ticket, candidato a ticket futuro (chequear si hay un
build activo antes de recrear el contenedor).

**Pendiente explícito, fuera de este ticket**: al retirar `ci.yml` de
`auth-core-mc`, el vhost `auth-core-mc.conf` y su certificado quedaron
sin ningún job que los reaplique si cambiaran (la renovación automática
del certificado sí sigue funcionando vía `certbot.timer` del sistema,
verificada). Si `auth-core-mc.conf` necesita cambiar en el futuro, hace
falta decidir un mecanismo nuevo — señalado a propósito, no resuelto
aquí.
