# 002 — Endurecer la infra base + runbook estándar para proyectos nuevos

## Objetivo
Marco pidió dejar la infra "al 100" antes de seguir construyendo cosas
nuevas (Vault, resize, etc.): que Jenkins/Traefik/SonarQube/Portainer
queden sólidos y que conectar un core nuevo (empezando por
`mail-core-mc`) sea mecánico, sin reinventar nada. Este ticket junta
todo lo encontrado en la conversación del 2026-08-31 al revisar a fondo
qué le falta a lo ya construido — ver memoria del equipo
`saas-paas-cores-strategy` para el detalle completo de cada hallazgo.

## Alcance

**1. Recreate seguro de Jenkins**
`sync-vm-infra` recrea el contenedor de Jenkins cuando cambia su
config, matando en seco cualquier build en curso (ya pasó una vez
durante el ticket 001, sin pérdida de datos, pero el riesgo sigue
latente). Antes de recrear, comprobar si Jenkins tiene un build activo
(`/computer/api/json` o equivalente) y esperar/reintentar en vez de
matarlo a ciegas.

**2. Resiliencia a reinicio de la VM**
Verificar `restart: unless-stopped` (o equivalente) en los 4 servicios
de infra compartida, y que el runner self-hosted arranca solo al
bootear la VM (systemd, no algo manual). Confirmar con evidencia real
(no asumir que ya está bien).

**3. Jenkins Shared Library**
Nueva, en este repo (`vars/` o `src/`, patrón estándar de Jenkins
Shared Libraries), con los pasos comunes de pipeline: build+test,
análisis SonarQube con Quality Gate, build de imagen, deploy
(dev/qa/prod), `cleanup.sh`, y — nuevo, ver punto 4 — aplicar el vhost
de nginx del proyecto. Cada `Jenkinsfile` de core queda reducido a
invocar la librería con sus parámetros propios (nombre del proyecto,
puertos, comando de build, etc.), no 200 líneas copiadas.
Registrar la librería en Jenkins (Manage Jenkins → System → Global
Pipeline Libraries) vía JCasC en `deploy/vm-infra/jenkins/casc/
jenkins.yaml` de este mismo repo.

**4. Vhost de nginx por proyecto — ya no huérfano**
Aplicar el vhost de nginx específico de cada core (ej.
`auth-core-mc.conf`) deja de depender de GitHub Actions del propio
proyecto (ya no existe) — se vuelve un paso de la Shared Library,
ejecutado por Jenkins en cada deploy a `dev`. Migrar
`auth-core-mc.conf` a este mecanismo nuevo como primer caso real
(verificar que sigue sirviendo `auth.64bitstudio.com` sin interrupción
después del cambio).

**5. Generalizar el `chmod` de permisos de secretos**
El paso "Permisos de grupo en los secrets de cada proyecto" en
`sync-vm-infra` está hardcodeado a `auth-core-mc` — generalizarlo
(iterar sobre todos los subdirectorios de `/home/ubuntu/secrets/` que
correspondan a proyectos, o mover la responsabilidad a la Shared
Library/Jenkinsfile de cada core, que ya sabe su propio nombre).

**6. Webhook GitHub→Jenkins automático por proyecto**
Hoy se creó a mano, por API, solo para `auth-core-mc`. Investigar si el
job "GitHub Organization" puede gestionar esto a nivel de organización
sin webhook por repo (más simple, revisar primero); si no es posible,
dejar el paso de creación del webhook como parte del runbook/script de
"proyecto nuevo" (punto 8), no como algo manual de una sola vez.

**7. Bootstrap de ramas `dev`/`qa`/`prod` + branch protection**
Ningún proceso crea las 3 ramas ni la branch protection
(`continuous-integration/jenkins/branch` como required check) en un
proyecto 100% nuevo. Script o pasos documentados y repetibles (vía
`gh api`) que, dado un repo recién creado con solo su rama default,
dejen `dev` como default, creen `qa`/`prod` desde ahí, y apliquen la
misma branch protection que ya tienen `dev`/`qa`/`prod` de
`auth-core-mc`.

**8. Runbook real: "cómo conecto un proyecto nuevo"**
Documento en `docs/ARQUITECTURA.md` de este repo (o un
`docs/RUNBOOK-PROYECTO-NUEVO.md` dedicado si queda más claro así) que
junte los puntos 3, 4, 5, 6, 7 en una secuencia clara de pasos —
suficiente para que conectar un core nuevo sea mecánico.

**9. Corregir el skill `bootstrap-proyecto`**
`~/.claude/skills/bootstrap-proyecto/SKILL.md` (fuera de cualquier
repo, config de Claude Code) sigue diciendo que SonarQube corre en la
Mac de Marco (retirado) y que hay que copiar un workflow de GitHub
Actions (ya no es el patrón). Actualizarlo para que apunte al
SonarQube de la VM y al `Jenkinsfile`+Shared Library — **este punto lo
hace Claude directamente, no el agente de DevOps** (no es infra de
ningún repo).

**10. Caso de prueba real: dejar `mail-core-mc` listo para arrancar**
Aplicar el runbook completo (puntos 3-8) a `mail-core-mc` — no su
pipeline de aplicación en sí (eso es su propio ticket 011, sin
empezar), solo la parte de infra: ramas, branch protection, webhook,
`Jenkinsfile` mínimo usando la Shared Library. Sirve como validación
real de que el runbook funciona, no solo teoría.

## No incluye
- El resize de la VM ni Vault (parqueados, pendientes del VoBo de
  Marco sobre `docs/definiciones/vault-secrets-manager-vm.md`).
- La ruta de hotfix urgente a prod — decisión explícita de no
  construirla todavía.
- El pipeline de aplicación real de `mail-core-mc` (ticket 011,
  separado) — este ticket solo deja la infra lista para que ese
  arranque sin fricción.

## Postura de riesgo
Nada opera de cara a clientes reales todavía (confirmado por Marco) —
no aplicar cautela de "downtime de producción" a este trabajo. Sí
verificar cada paso con evidencia real.

## Criterios de aceptación
- Dado un push que cambia la config de Jenkins, cuando hay un build
  activo, entonces NO lo mata en seco (verificado provocándolo de
  verdad, no solo revisando el código).
- Dado un reinicio real de la VM, entonces los 4 servicios de infra y
  el runner vuelven solos, sin intervención manual.
- Dado el `Jenkinsfile` de `auth-core-mc` reescrito para usar la Shared
  Library, entonces el pipeline completo (build/test/Sonar/deploy/
  vhost) sigue funcionando igual que antes — verificado con un deploy
  real a DEV.
- Dado `mail-core-mc` tras aplicar el runbook, entonces tiene sus 3
  ramas, branch protection, webhook a Jenkins, y un `Jenkinsfile`
  mínimo que Jenkins descubre y puede correr (aunque su lógica de
  negocio real sea mínima/placeholder, ese es alcance del ticket 011).
- Dado el skill `bootstrap-proyecto` corregido, entonces ya no
  menciona Sonar en la Mac ni "copiar workflow de GitHub Actions".
