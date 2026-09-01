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
