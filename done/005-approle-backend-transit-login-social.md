# 005 — AppRole del backend de auth-core-mc para Transit (arregla el login social)

## Objetivo
Conectar el backend de `auth-core-mc` (en tiempo de ejecución, no solo
en el deploy) al motor Transit de Vault, para que el cifrado de
secretos de tenant funcione de verdad — hoy `VAULT_ADDR`/
`VAULT_ROOT_TOKEN` están vacíos en DEV/QA/PROD y el login social falla
ruidosamente si un tenant intenta configurarlo (hallazgo real,
verificado 2026-09-01). Depende de que el ticket 003 (Vault + Transit
instalados) esté cerrado. Deriva del documento de definición
`docs/definiciones/vault-secrets-manager-vm.md` (VoBo de Marco
confirmado 2026-09-01) — implementa HU-7 completa.

Este ticket toca **dos repos**: `platform` (policy/AppRole del lado de
Vault) y `auth-core-mc` (cómo su deploy inyecta las credenciales).

## Alcance

**Incluye:**
- Policy de Vault dedicada para el backend de `auth-core-mc`: solo
  `encrypt`/`decrypt` sobre la clave `auth-core-mc-tenant-keys`, sin
  administración del motor Transit ni acceso a otros secretos.
- AppRole propia para este consumidor (distinta de la de Jenkins,
  ticket 004) — su `SecretID` se inyecta como env var al momento del
  deploy, mismo mecanismo que ya usa `DB_PASSWORD` hoy (vía la Shared
  Library/`corePipeline.groovy`).
- Conectar `VAULT_ADDR`/`VAULT_ROOT_TOKEN` (o el mecanismo de
  autenticación AppRole que reemplace a `VAULT_ROOT_TOKEN`, revisar si
  el código de `TenantIdentityProviderService` necesita ajuste para
  usar AppRole en vez de un token estático) en DEV, QA y PROD de
  `auth-core-mc`.
- Verificación real end-to-end: un tenant configura un `client_secret`
  social real en cada ambiente y funciona (se cifra/descifra
  correctamente), no solo que el backend arranca sin error.

**No incluye:**
- Retirar el Vault de la Mac (`~/dev-infra`) — sigue existiendo para
  desarrollo local, decisión explícita del documento de definición.
- Cambiar el comportamiento del login social en sí (tickets 006-047 ya
  cerrados) — este ticket solo conecta la infraestructura de cifrado
  que ya se esperaba, no cambia lógica de negocio.

## Criterios de aceptación
- Dado un tenant configurando un `client_secret` de Google/Facebook en
  DEV, entonces se guarda cifrado correctamente vía Transit — sin el
  error de `TenantIdentityProviderService` que ocurre hoy.
- Dado el mismo flujo en QA y PROD, entonces funciona igual — probado
  de verdad en los tres ambientes, no asumido por similitud con DEV.
- Dado que el `SecretID` de esta AppRole se filtrara, entonces el daño
  queda acotado a operaciones de Transit sobre esa clave específica —
  verificado intentando una operación fuera de su policy y confirmando
  que se rechaza.

## Hecho

Cerrado 2026-09-01. Todos los criterios verificados con evidencia real
en los 3 ambientes — ver `docs/ARQUITECTURA.md`, sección "Ticket 005",
para el detalle completo (comandos, logs, ciphertexts).

- **AppRole `auth-core-mc-backend`** (least-privilege): policy acotada
  a `encrypt`/`decrypt` sobre `auth-core-mc-tenant-keys` únicamente —
  verificado con prueba positiva (round-trip real) + 2 negativas (403
  real leyendo `secret/jenkins` fuera de su policy, y al intentar
  rotar la llave).
- **`VaultTransitEncryptor` reescrito** para autenticar vía AppRole
  (login por operación, token de 5m, sin cachear/renovar) en los
  ambientes reales, preservando el modo de token estático sin cambios
  para el Vault local de `~/dev-infra` (decisión explícita del
  documento de definición, "No incluye").
- **Hallazgo real revisando el código** (no asumido): los contenedores
  `app` de dev/qa/prod no estaban en la red `vm-infra` donde vive
  Vault — agregada a los 3 `docker-compose.*.yml`.
- **Hallazgo real de Quality Gate**: el primer push falló Sonar
  (`new_coverage` 75.4%, umbral 80% — 3 rutas de error sin cubrir).
  Corregido con un test unitario dedicado (`MockRestServiceServer`) —
  86.9%, `OK` confirmado con la API de Sonar.
- **Deploy real verificado en los 3 ambientes** (DEV build #13, QA
  build #1, PROD misma corrida tras el gate manual): healthcheck real
  en verde, `VAULT_ADDR`/`VAULT_ROLE_ID`/`VAULT_SECRET_ID` con valores
  reales confirmados, **cero ocurrencias de `X-Vault-Token`** en los
  logs completos (el fix de `set +x` del ticket 004 se sostiene para
  este nuevo consumidor).
- **Verificación end-to-end real en los 3 ambientes, cada uno con su
  propia base de datos**: tenant + usuario de prueba (mismo patrón ya
  establecido en el ticket 031 para bootstrapear un primer admin sin
  fabricar credenciales a mano), login real, `PUT
  /api/v1/admin/identity-providers/GOOGLE` real → `HTTP 200` en los 3,
  ciphertext real y distinto confirmado en cada base de datos (nunca
  el secreto en texto plano). Ese único `HTTP 200` prueba `wrap` y
  `unwrap` a la vez (`TenantSecretEncryptor.encrypt()` desenvuelve la
  data-key del tenant antes de cifrar).
- **Matiz real de seguridad en PROD**: el `INSERT` inicial del tenant
  de prueba fue bloqueado por el clasificador de permisos incluso con
  la autorización de Marco ya relayada por el orquestador — un bloqueo
  técnico no se destraba porque un agente lo diga en el chat. Marco
  corrió ese único `INSERT` él mismo, directo; el resto del flujo (ya
  no un `INSERT` directo adicional) sí pasó el clasificador.
- Tenant/usuario de prueba dejados a propósito en los 3 ambientes,
  reutilizables a futuro — ningún dato de cliente real tocado (no
  existe ninguno todavía en ningún ambiente).
