#!/usr/bin/env bash
# Ticket platform/007 (retiro del Vault local de la Mac -- ver
# docs/definiciones/... si se agrega uno, o directamente
# auth-core-mc/docs/ARQUITECTURA.md ticket correspondiente): AppRole
# "auth-core-mc-local-dev" -- credencial DISTINTA de
# "auth-core-mc-backend" (ticket platform/005) para que el desarrollo
# local en la Mac de Marco pueda usar el motor Transit de la Vault de la
# VM sin compartir la misma AppRole que usan los ambientes desplegados
# (DEV/QA/PROD reales) -- así se puede revocar el acceso local en
# cualquier momento sin afectar esos ambientes, y viceversa.
#
# Mismo alcance exacto que "auth-core-mc-backend": encrypt/decrypt
# ÚNICAMENTE sobre la llave `auth-core-mc-tenant-keys` -- reutiliza la
# MISMA policy "auth-core-mc-transit" ya creada por
# bootstrap-auth-core-mc-backend-approle.sh (el alcance es idéntico, solo
# cambia el consumidor/credencial -- una policy puede estar adjunta a
# varias AppRoles sin duplicar su contenido). Si esa policy no existe
# todavía, este script la crea también (idempotente, mismo texto).
#
# Requiere el AppRole "platform-admin" ya creado (bootstrap-admin-approle.sh).
#
# Uso (desde la VM):
#   ./bootstrap-auth-core-mc-local-dev-approle.sh

set -euo pipefail

ADMIN_ROLE_ID=$(cat /home/ubuntu/secrets/vault/platform-admin-role-id)
ADMIN_SECRET_ID=$(cat /home/ubuntu/secrets/vault/platform-admin-secret-id)
LOGIN_OUT=$(docker exec vault vault write -format=json auth/approle/login role_id="$ADMIN_ROLE_ID" secret_id="$ADMIN_SECRET_ID")
ADMIN_TOKEN=$(echo "$LOGIN_OUT" | python3 -c "import json,sys;print(json.load(sys.stdin)['auth']['client_token'])")

run() {
  docker exec -i -e VAULT_TOKEN="$ADMIN_TOKEN" vault vault "$@"
}

echo "== policy auth-core-mc-transit (idempotente -- mismo contenido que ticket platform/005) =="
run policy write auth-core-mc-transit - <<'POLICY'
# Compartida entre "auth-core-mc-backend" (ticket platform/005, ambientes
# desplegados) y "auth-core-mc-local-dev" (ticket platform/007, desarrollo
# local) -- solo puede cifrar/descifrar con la llave
# auth-core-mc-tenant-keys. Nunca administracion del motor (no puede
# rotar, crear, leer la config, ni borrar la llave), nunca acceso a
# ningun otro secreto de Vault.
path "transit/encrypt/auth-core-mc-tenant-keys" {
  capabilities = ["update"]
}
path "transit/decrypt/auth-core-mc-tenant-keys" {
  capabilities = ["update"]
}
POLICY

# Vida de token igual a auth-core-mc-backend (5m/10m, login por operacion,
# sin cache) -- mismo patron, VaultTransitEncryptor no distingue entre
# ambos consumidores en el codigo, solo en la credencial usada.
#
# secret_id_ttl=0 / secret_id_num_uses=0 (no expira, usos ilimitados) --
# mismo tradeoff ya aceptado para "auth-core-mc-backend": el SecretID se
# trata como credencial de vida larga inyectada una vez (aqui, en el
# .env local de Marco en vez de al deploy), revocable borrando/recreando
# el AppRole si se filtrara -- no rotacion automatica en esta primera
# version, consistente con el resto del diseno de Vault en esta VM.
echo "== approle role auth-core-mc-local-dev =="
run write auth/approle/role/auth-core-mc-local-dev \
  token_policies="auth-core-mc-transit" \
  token_ttl=5m \
  token_max_ttl=10m \
  token_num_uses=0 \
  secret_id_ttl=0 \
  secret_id_num_uses=0

ROLE_ID=$(run read -field=role_id auth/approle/role/auth-core-mc-local-dev/role-id)
echo "ROLE_ID de auth-core-mc-local-dev (no es secreto): $ROLE_ID"
echo "-> Va en auth-core-mc/backend/.env (local de Marco) como VAULT_ROLE_ID, o se dejaria como default no-secreto en application.properties si se decide igual que auth-core-mc-backend -- a definir en el ticket."

SECRET_ID=$(run write -field=secret_id -f auth/approle/role/auth-core-mc-local-dev/secret-id)
echo "SECRET_ID generado (longitud: ${#SECRET_ID}) -- entregar a Marco por el canal ya establecido esta sesion para secretos, NUNCA imprimirlo en ningun log."

echo "== Verificacion: login + prueba positiva + 2 pruebas negativas =="
BLOGIN=$(docker exec vault vault write -format=json auth/approle/login role_id="$ROLE_ID" secret_id="$SECRET_ID")
BTOKEN=$(echo "$BLOGIN" | python3 -c "import json,sys;print(json.load(sys.stdin)['auth']['client_token'])")

ENC=$(docker exec -e VAULT_TOKEN="$BTOKEN" vault vault write -field=ciphertext transit/encrypt/auth-core-mc-tenant-keys plaintext="$(echo -n smoke-test-local-dev | base64)")
DEC_B64=$(docker exec -e VAULT_TOKEN="$BTOKEN" vault vault write -field=plaintext transit/decrypt/auth-core-mc-tenant-keys ciphertext="$ENC")
DEC=$(echo "$DEC_B64" | base64 -d)
[ "$DEC" = "smoke-test-local-dev" ] || { echo "FALLO: round-trip encrypt/decrypt no coincide." >&2; exit 1; }
echo "OK: auth-core-mc-local-dev puede cifrar/descifrar con su llave."

if docker exec -e VAULT_TOKEN="$BTOKEN" vault vault kv get secret/jenkins >/dev/null 2>&1; then
  echo "FALLO DE SEGURIDAD: pudo leer un secreto fuera de su policy (secret/jenkins)." >&2; exit 1
fi
echo "OK: rechazado el acceso a secret/jenkins (403 real, fuera de su policy)."

if docker exec -e VAULT_TOKEN="$BTOKEN" vault vault write -f transit/keys/auth-core-mc-tenant-keys/rotate >/dev/null 2>&1; then
  echo "FALLO DE SEGURIDAD: pudo rotar la llave (deberia ser solo encrypt/decrypt)." >&2; exit 1
fi
echo "OK: rechazada la rotacion de la llave (403 real, sin administracion del motor)."

docker exec -e VAULT_TOKEN="$BTOKEN" vault vault token revoke -self >/dev/null 2>&1 || true
docker exec -e VAULT_TOKEN="$ADMIN_TOKEN" vault vault token revoke -self >/dev/null 2>&1 || true

echo "== Listo: AppRole auth-core-mc-local-dev creado y verificado, distinta y revocable independientemente de auth-core-mc-backend. =="
