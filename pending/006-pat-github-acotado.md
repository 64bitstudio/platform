# 006 — PAT de GitHub nuevo y acotado, guardado en Vault

## Objetivo
Reemplazar el PAT de GitHub compartido actual (permisos de
administrador, puede saltarse branch protection — hallazgo real del
ticket `platform/002`, incidente del push directo a `dev` de
`mail-core-mc`) por uno nuevo con el mínimo scope necesario, guardado
en Vault. Depende de que el ticket 003 (Vault instalado) esté cerrado
— no depende estrictamente de 004/005, pero tiene sentido hacerlo
después de que la migración de secretos de infra (004) ya esté
funcionando, para no tocar credenciales de Jenkins dos veces. Deriva
del documento de definición
`docs/definiciones/vault-secrets-manager-vm.md` (VoBo de Marco
confirmado 2026-09-01) — implementa HU-9.

## Alcance

**Incluye:**
- Generar un PAT nuevo (fine-grained), con el scope mínimo real
  confirmado (a determinar exacto al implementar — probablemente
  `contents:write`, `metadata:read`, `webhooks:write`, sin
  `administration`) sobre `64bitstudio/*`.
- Guardarlo en Vault, reemplazando al PAT actual en el credential store
  de Jenkins.
- Verificar que Jenkins sigue pudiendo hacer checkout/push/gestionar
  webhooks con el PAT nuevo — sin regresión en ningún pipeline
  existente (`auth-core-mc`, `mail-core-mc`).
- Revocar el PAT viejo una vez confirmado que el nuevo funciona de
  punta a punta (no antes — evitar quedarse sin credencial funcional a
  mitad del cambio).

**No incluye:**
- Cambiar el mecanismo de creación de webhooks (`gh api` en el script
  de bootstrap, ya resuelto en el ticket 002) — el PAT nuevo debe seguir
  funcionando con ese mismo mecanismo, no se rediseña aquí.

## Criterios de aceptación
- Dado el PAT nuevo ya en uso, cuando se intenta un push directo a una
  rama protegida (mismo escenario del incidente del ticket 002),
  entonces GitHub lo rechaza — a diferencia de hoy, que lo permite con
  aviso de "bypass". Verificado provocándolo de verdad (en una rama de
  prueba, no en `dev`/`qa`/`prod` reales).
- Dado un push normal a una rama de feature, entonces el pipeline de
  Jenkins sigue funcionando exactamente igual que antes (checkout,
  build, deploy, creación de webhook para un repo nuevo) — sin ninguna
  regresión.
- Dado el PAT viejo ya revocado, entonces cualquier intento de usarlo
  falla — confirmado, no asumido.
