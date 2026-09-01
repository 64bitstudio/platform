# 004 — AppRole de Jenkins + migración de secretos de infra

## Objetivo
Integrar la autenticación de Jenkins contra Vault (AppRole) directamente
en la Shared Library (`vars/corePipeline.groovy`), y migrar los
secretos de infra ya existentes desde archivos sueltos a Vault, uno a
la vez. Depende de que el ticket 003 (Vault instalado) esté cerrado.
Deriva del documento de definición
`docs/definiciones/vault-secrets-manager-vm.md` (VoBo de Marco
confirmado 2026-09-01) — implementa HU-1 (completa), HU-3, HU-4 y HU-8.

## Alcance

**Incluye:**
- Policy de Vault de mínimo privilegio para Jenkins (lee solo los
  paths de secretos que su pipeline necesita, nunca el árbol completo).
- AppRole de Jenkins (`RoleID` + `SecretID`) — `RoleID` en el propio
  `Jenkinsfile`/Shared Library (no es secreto), `SecretID` como el
  único bootstrap secret en el credential store de Jenkins (UI).
- Step reusable en `vars/corePipeline.groovy` que hace login AppRole y
  lee los secretos que cada core declare necesitar — así cualquier core
  que use la librería queda cubierto sin tocar su propio `Jenkinsfile`
  más allá de declarar qué paths necesita.
- Migración de secretos, en este orden, verificando cada paso antes de
  seguir: `DB_PASSWORD` de DEV de `auth-core-mc` → QA → PROD → PAT de
  GitHub y `SONAR_TOKEN`/tokens de Telegram de Jenkins → hash de Basic
  Auth de nginx.
- **Alerta por Telegram si Vault queda sellado/inalcanzable** (HU-8) —
  `sync-vm-infra` verifica `vault status` y dispara la misma
  notificación que ya usa para éxito/fallo del pipeline.

**No incluye:**
- El motor Transit ni la AppRole del backend de `auth-core-mc` (ticket
  005).
- El PAT nuevo acotado (ticket 006) — este ticket migra el PAT
  *actual* a Vault tal cual, sin cambiar sus permisos todavía.

## Criterios de aceptación
- Dado un build de Jenkins que necesita `DB_PASSWORD` de un ambiente,
  entonces lo obtiene de Vault vía AppRole, con un token que solo puede
  leer esos paths — verificado intentando leer un path fuera de su
  policy y confirmando que se rechaza.
- Dado cada secreto migrado, entonces el archivo/valor original deja de
  ser la fuente de verdad — verificado con un deploy real después de la
  migración, no solo revisando el código.
- Dado que algo falla a mitad de la migración de un ambiente, entonces
  existe rollback real al archivo original (no se borra hasta confirmar
  Vault de punta a punta para ese ambiente).
- Dado que Vault queda sellado/inalcanzable de verdad (probado
  provocándolo), entonces llega una alerta real por Telegram.

## Hecho

Cerrado 2026-09-01. Todos los criterios verificados con evidencia real
— ver `docs/ARQUITECTURA.md`, sección "Ticket 004", para el detalle
completo (logs, comandos, timestamps).

- **AppRole `platform-admin`** (permanente, acotado) — decisión nueva
  de Marco sumada durante este ticket (adenda en
  `docs/definiciones/vault-secrets-manager-vm.md`): el agente necesitaba
  una credencial administrativa continua tras borrar el token root del
  ticket 003. `deploy/vm-infra/vault/bootstrap-admin-approle.sh`
  (idempotente), verificado con pruebas reales positivas y negativas
  (403 confirmado al intentar sellar Vault o montar un secrets engine
  nuevo). Hallazgo real corregido en vivo: faltaba `transit/*` en la
  policy (encontrado en el primer run real de `sync-vm-infra`).
- **5 secretos migrados a Vault**
  (`deploy/vm-infra/vault/migrate-infra-secrets.sh`): `DB_PASSWORD` de
  dev/qa/prod de `auth-core-mc`, PAT de GitHub + `SONAR_TOKEN` + tokens
  de Telegram de Jenkins, hash de Basic Auth de nginx — cada uno
  verificado con lectura de vuelta (round-trip), no solo "el comando no
  falló".
- **AppRole `jenkins-infra`** (solo lectura, least-privilege) —
  `deploy/vm-infra/vault/bootstrap-jenkins-approle.sh`. Verificado con
  prueba positiva + 3 pruebas negativas reales: **403 confirmado** al
  leer un ambiente fuera de dev/qa/prod, al intentar escribir, y al
  intentar leer datos administrativos de otro AppRole — cumple
  exactamente el criterio de aceptación ("verificado intentando leer un
  path fuera de su policy y confirmando que se rechaza").
- **`vars/corePipeline.groovy`**: `fetchAndPatchDbPasswordFromVault`,
  automático antes de cada deploy (DEV/QA/PROD) para cualquier core con
  `deploy: true` — verificado que NO afecta a `mail-core-mc` (Jenkinsfile
  ya tiene `deploy: false`, confirmado leyendo el archivo real, no
  asumido).
- **HU-8 (alerta de Vault sellado)**: paso dedicado en `sync-vm-infra`,
  con `TELEGRAM_BOT_TOKEN`/`TELEGRAM_CHAT_ID` configurados como GitHub
  Actions Secrets reales (reusando el bot/chat que Marco ya usa para
  notificaciones locales) — confirmado con la API (`total_count: 0` →
  `2`). Los 3 `curl` a Telegram del archivo (HU-8 + Notify success +
  Notify failure) revisan ahora el código HTTP real y el campo `ok` de
  la respuesta — **verificado en un run real que la notificación de
  éxito se entregó de verdad** (HTTP 200 + `ok:true`), la primera
  entrega confirmada desde que este job existe.
- **Deploy real verificado de punta a punta** (criterio de aceptación
  explícito, "no solo revisando el código"): push real a `dev` de
  `auth-core-mc` (build #11 de Jenkins) — login AppRole real, fetch de
  Vault real, `DB_PASSWORD` parcheado en el `.env.dev` real de la VM
  (confirmado valor + `mtime` coincidente con el build), deploy y
  healthcheck normales.
- **Hallazgo real de seguridad, encontrado en esa misma verificación y
  ya corregido**: el token de Vault de vida corta quedaba impreso en
  texto plano en el log de Jenkins (`set -x` de la shell, sin masking
  automático porque no es un credential registrado). Token expuesto
  revocado a mano de inmediato (`vault token revoke -self`); fix real
  (`set +x` en `fetchAndPatchDbPasswordFromVault`) verificado con un
  **segundo** deploy real (build #12) — cero ocurrencias de
  `X-Vault-Token` en el log completo, y el mecanismo de fetch+patch
  confirmado que sigue funcionando (mismo chequeo de `mtime`).
- **`SONAR_TOKEN`/`SONAR_HOST_URL`**: señalado explícitamente como NO
  resuelto — el valor local de la Mac de Marco apunta a su SonarQube
  local (`localhost:9000` desde su propia máquina), una instancia
  distinta a la de la VM (separadas desde el ticket 049) — no se asumió
  ni se copió un valor que fallaría. Pendiente como pregunta aparte,
  sin impacto práctico inmediato (el `SONAR_TOKEN` de Jenkins ya vive en
  Vault con un valor real).
