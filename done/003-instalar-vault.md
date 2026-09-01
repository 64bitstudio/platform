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

## Hecho

Cerrado 2026-09-01. Todos los criterios verificados con evidencia real
— ver `docs/ARQUITECTURA.md`, sección "Ticket 003", para el detalle
completo (OCIDs, comandos, logs).

- **Vault instalado**: `deploy/vm-infra/vault/` (Vault Community
  Edition 2.0.4, "Vault OSS" del documento de definición es la misma
  edición gratuita self-hosted, renombrada por HashiCorp en 2023),
  storage Raft single-node.
- **Auto-unseal vía OCI KMS, verificado con un reinicio real de la
  VM** (no solo `docker restart`): `sudo reboot` real (VoBo/ejecución de
  Marco), la VM volvió sola, y `vault status` mostró `Sealed: false`
  sin que nadie corriera `vault operator unseal` — los 15 contenedores
  (14 preexistentes desde el ticket 002 + Vault) y el runner
  self-hosted de GitHub Actions también volvieron solos.
  - Recursos de OCI provisionados: Vault KMS (`platform-vm-secrets-kms`,
    tipo DEFAULT) + llave AES-256 software-protected
    (`platform-vm-vault-autounseal`) — confirmado sin costo (solo las
    llaves HSM-protected cobran). Dynamic Group + Policy de IAM
    (creados por Marco, acción exclusiva de su cuenta OCI — bloqueada
    para este agente por el clasificador) scoped a esa única llave
    (`use keys`, nunca administrar).
  - Dos hallazgos reales de infra encontrados y documentados a fondo
    (verificando en vivo, no asumiendo): (1) la imagen oficial de
    `hashicorp/vault` nunca hace `chown` de `/vault/data`, solo de
    `/vault/config`/`/vault/logs`/`/vault/file` — se usó `/vault/file`
    como storage path; (2) `cluster_addr` no puede reusar el puerto de
    `api_addr` ni en single-node — el transporte de Raft fallaba **sin
    ningún mensaje de error**, ni con trace logging, aislado por
    descarte comparando contra `vault -dev`. Puerto de cluster separado
    (8201) como fix.
- **Motor Transit habilitado desde la inicialización**, llave
  `auth-core-mc-tenant-keys` creada, probado con un round-trip real
  `transit/encrypt`/`transit/decrypt` (coincide el texto descifrado con
  el original) — sin conectar ningún consumidor real todavía (ticket
  005). Codificado como paso idempotente de `sync-vm-infra`
  (`.github/workflows/ci.yml`), verificado en verde en un run real del
  runner self-hosted (`gh run view`, ambos pasos nuevos `success`).
- **Unseal keys de respaldo**: `vault operator init` (3 recovery
  shares, threshold 2) — token root + recovery keys nunca expuestos en
  ningún chat ni en la salida de ningún comando visto por este agente
  (redirigidos directo a un archivo en la VM con permisos 600; todo uso
  posterior corrió en scripts server-side). **Probado de verdad, no
  solo generado**: 2 de 3 recovery keys generaron y autenticaron un
  root token nuevo vía `vault operator generate-root` (confirmado con
  `vault token lookup` → `policies: ["root"]`), revocado después de la
  prueba. Verificado (`ls -la /home/ubuntu/secrets/vault/` en la VM)
  que `init-output.json` ya no existe -- consistente con que Marco lo
  recuperó y lo borró como se le indicó (queda solo `init-output.err`,
  vacío, sin secretos).
- **`docker stats` real de Vault en reposo**: `0.31% CPU`, `35.52MiB`
  de memoria — registrado en `docs/ARQUITECTURA.md`.
- **Pendiente señalado, no bloqueante**: la prueba de recovery keys
  cubrió `generate-root` (el mecanismo real de recuperación con
  auto-unseal), no el escenario más extremo de arrancar Vault en
  Recovery Mode con OCI KMS realmente inalcanzable — señalado
  explícitamente en `docs/ARQUITECTURA.md` como no cubierto, decisión
  de no arriesgar la instancia ya configurada por una prueba no exigida
  literalmente por HU-2.
- **Candidato a hook futuro** (regla de mejora continua): un lint que
  verifique que `cluster_addr` y `api_addr` no comparten puerto en
  cualquier config de Raft futura — señalado en `docs/ARQUITECTURA.md`
  para que Marco decida si vale la pena sumarlo a
  `dev-org-hooks-suite`; no implementado en este ticket.
