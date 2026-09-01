# 003 — Instalar Vault (Raft, auto-unseal OCI KMS, Transit habilitado)

## Objetivo
Instalar Vault OSS en la VM compartida como base de la infra de
secretos. Este ticket es **solo la infra base** — no migra ningún
secreto todavía (eso es el ticket 004) ni conecta el motor Transit al
backend de `auth-core-mc` (eso es el ticket 005). Deriva del documento
de definición `docs/definiciones/vault-secrets-manager-vm.md` (VoBo de
Marco confirmado 2026-09-01) — ver ahí el diseño completo, tradeoffs y
alternativas descartadas; este ticket implementa HU-1 (parcial) y HU-2
de ese documento.

## Alcance

**Incluye:**
- `deploy/vm-infra/vault/docker-compose.yml` (mismo patrón que
  Traefik/SonarQube/Jenkins/Portainer) — Vault OSS, storage backend
  Raft integrado, modo single-node.
- Configuración de **auto-unseal vía OCI KMS** — clave de OCI KMS
  dedicada, Vault se desella solo al arrancar el contenedor.
- **Motor Transit habilitado desde la inicialización**, con la clave
  `auth-core-mc-tenant-keys` (nombre que el código de `auth-core-mc` ya
  espera vía `VAULT_TRANSIT_KEY_NAME`) — sin conectar todavía ningún
  consumidor real (eso es el ticket 005).
- Generación de las unseal keys (Shamir) y entrega a Marco para
  guardarlas en su gestor de contraseñas como respaldo manual.
- Extender `sync-vm-infra` para mantener el contenedor de Vault al día
  (mismo patrón que el resto de la infra compartida).
- Medición real de CPU/memoria de Vault en reposo (`docker stats`),
  registrada en `docs/ARQUITECTURA.md` — sin límite predefinido, solo
  medir y dejar evidencia.

**No incluye:**
- Migrar ningún secreto existente (ticket 004).
- AppRole de Jenkins ni de `auth-core-mc` (tickets 004 y 005).
- Alerta de Telegram si Vault se sella (ticket 004, HU-8).
- PAT nuevo acotado (ticket 006).

## Criterios de aceptación
- Dado un reinicio real de la VM, cuando Vault arranca, entonces queda
  desellado automáticamente vía OCI KMS, sin intervención manual.
- Dado el motor Transit habilitado, cuando se prueba manualmente
  (`vault write transit/encrypt/auth-core-mc-tenant-keys ...`), entonces
  cifra/descifra correctamente — sin necesitar todavía que ningún
  consumidor real lo use.
- Dado el `docker stats` real de Vault en reposo, entonces queda
  registrado en `docs/ARQUITECTURA.md` con el número real, no estimado.
- Dado que Marco pierde acceso a la consola de OCI, entonces puede
  desellar Vault manualmente con las unseal keys guardadas en su gestor
  de contraseñas — probado al menos una vez de verdad, no solo teórico.
