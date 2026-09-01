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
