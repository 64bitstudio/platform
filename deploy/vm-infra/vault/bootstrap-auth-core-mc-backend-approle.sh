#!/usr/bin/env bash
# Ticket platform/005 (docs/definiciones/vault-secrets-manager-vm.md,
# HU-7): AppRole "auth-core-mc-backend" -- consumidor de Transit EN
# TIEMPO DE EJECUCIÓN (no solo deploy, a diferencia de "jenkins-infra")
# para el backend de auth-core-mc. Policy acotada a encrypt/decrypt
# sobre la llave `auth-core-mc-tenant-keys` únicamente -- sin
# administración del motor Transit (no puede rotar/crear/borrar
# llaves) ni acceso a ningún otro secreto. Distinta de "jenkins-infra"
# (ticket 004) -- consumidores separados, policies separadas, mismo
# principio de mínimo privilegio. Requiere el AppRole "platform-admin"
# ya creado (ver bootstrap-admin-approle.sh).
#
# Diseño: el backend hace login AppRole EN CADA operación de wrap/
# unwrap (no mantiene un token de larga duración en memoria) -- ver
# VaultTransitEncryptor.java en auth-core-mc. Simplifica el código
# (sin lógica de renovación/expiración de token) a cambio de un
# round-trip extra por operación -- aceptable porque configurar un
# secreto de login social es una operación de administración poco
# frecuente, no un hot path de cada request. Por eso el TTL del token
# puede ser corto (se usa una sola vez, de inmediato).
#
# Idempotente: seguro de re-correr. Si el ROLE_ID cambia (recreación
# desde cero), hay que actualizar VAULT_ROLE_ID en
# auth-core-mc/backend/src/main/resources/application.properties
# también -- el script lo imprime al final como recordatorio.
#
# Uso (desde la VM):
#   ./bootstrap-auth-core-mc-backend-approle.sh

set -euo pipefail

ADMIN_ROLE_ID=$(cat /home/ubuntu/secrets/vault/platform-admin-role-id)
ADMIN_SECRET_ID=$(cat /home/ubuntu/secrets/vault/platform-admin-secret-id)
LOGIN_OUT=$(docker exec vault vault write -format=json auth/approle/login role_id="$ADMIN_ROLE_ID" secret_id="$ADMIN_SECRET_ID")
ADMIN_TOKEN=$(echo "$LOGIN_OUT" | python3 -c "import json,sys;print(json.load(sys.stdin)['auth']['client_token'])")

run() {
  docker exec -i -e VAULT_TOKEN="$ADMIN_TOKEN" vault vault "$@"
}

echo "== policy auth-core-mc-transit (solo encrypt/decrypt sobre una llave especifica) =="
run policy write auth-core-mc-transit - <<'POLICY'
# AppRole del backend de auth-core-mc para Transit (ticket platform/005,
# HU-7) -- solo puede cifrar/descifrar con la llave
# auth-core-mc-tenant-keys. Nunca administración del motor (no puede
# rotar, crear, leer la config, ni borrar la llave), nunca acceso a
# ningun otro secreto de Vault.
path "transit/encrypt/auth-core-mc-tenant-keys" {
  capabilities = ["update"]
}
path "transit/decrypt/auth-core-mc-tenant-keys" {
  capabilities = ["update"]
}
POLICY

echo "== approle role auth-core-mc-backend =="
run write auth/approle/role/auth-core-mc-backend \
  token_policies="auth-core-mc-transit" \
  token_ttl=5m \
  token_max_ttl=10m \
  token_num_uses=0 \
  secret_id_ttl=0 \
  secret_id_num_uses=0

ROLE_ID=$(run read -field=role_id auth/approle/role/auth-core-mc-backend/role-id)
echo "ROLE_ID de auth-core-mc-backend (no es secreto): $ROLE_ID"
echo "-> Si este valor difiere del que ya vive en auth-core-mc/backend/src/main/resources/application.properties (vault.role-id), hay que actualizarlo ahi."

# El SecretID SI es secreto -- se agrega a los 3 KV de infra
# (secret/auth-core-mc/dev|qa|prod), mismo valor en los 3 (una sola
# AppRole compartida entre ambientes, igual que jenkins-infra), nunca
# impreso. corePipeline.groovy ya lee estos KV para DB_PASSWORD -- se
# extiende para tambien parchear VAULT_SECRET_ID en el .env real de
# cada ambiente en cada deploy.
SECRET_ID=$(run write -field=secret_id -f auth/approle/role/auth-core-mc-backend/secret-id)
for ENV in dev qa prod; do
  # Read-merge-write en vez de "vault kv patch" -- evita depender de la
  # capability ACL "patch" (distinta de create/read/update/delete/list,
  # no otorgada explícitamente a platform-admin) para algo que
  # read+write ya resuelve con los permisos que ya tiene.
  CURRENT_DB_PASSWORD=$(run kv get -field=DB_PASSWORD "secret/auth-core-mc/${ENV}")
  run kv put "secret/auth-core-mc/${ENV}" DB_PASSWORD="$CURRENT_DB_PASSWORD" VAULT_SECRET_ID="$SECRET_ID" >/dev/null
  echo "VAULT_SECRET_ID agregado a secret/auth-core-mc/${ENV} (DB_PASSWORD preservado)."
done

echo "== Verificacion: login + prueba positiva + 2 pruebas negativas =="
BLOGIN=$(docker exec vault vault write -format=json auth/approle/login role_id="$ROLE_ID" secret_id="$SECRET_ID")
BTOKEN=$(echo "$BLOGIN" | python3 -c "import json,sys;print(json.load(sys.stdin)['auth']['client_token'])")

ENC=$(docker exec -e VAULT_TOKEN="$BTOKEN" vault vault write -field=ciphertext transit/encrypt/auth-core-mc-tenant-keys plaintext="$(echo -n smoke-test-005 | base64)")
DEC_B64=$(docker exec -e VAULT_TOKEN="$BTOKEN" vault vault write -field=plaintext transit/decrypt/auth-core-mc-tenant-keys ciphertext="$ENC")
DEC=$(echo "$DEC_B64" | base64 -d)
[ "$DEC" = "smoke-test-005" ] || { echo "FALLO: round-trip encrypt/decrypt no coincide." >&2; exit 1; }
echo "OK: auth-core-mc-backend puede cifrar/descifrar con su llave."

if docker exec -e VAULT_TOKEN="$BTOKEN" vault vault kv get secret/jenkins >/dev/null 2>&1; then
  echo "FALLO DE SEGURIDAD: pudo leer un secreto fuera de su policy (secret/jenkins)." >&2; exit 1
fi
echo "OK: rechazado el acceso a secret/jenkins (403 real, fuera de su policy)."

if docker exec -e VAULT_TOKEN="$BTOKEN" vault vault write -f transit/keys/auth-core-mc-tenant-keys/rotate >/dev/null 2>&1; then
  echo "FALLO DE SEGURIDAD: pudo rotar la llave (deberia ser solo encrypt/decrypt)." >&2; exit 1
fi
echo "OK: rechazada la rotacion de la llave (403 real, sin administracion del motor)."

echo "== Listo: AppRole auth-core-mc-backend creado y verificado. =="
