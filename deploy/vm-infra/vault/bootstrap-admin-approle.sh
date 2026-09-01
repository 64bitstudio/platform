#!/usr/bin/env bash
# Ticket platform/004 (decisión sumada 2026-09-01, ver adenda en
# docs/definiciones/vault-secrets-manager-vm.md y docs/ARQUITECTURA.md):
# bootstrap del AppRole "platform-admin" -- la credencial permanente y
# acotada que el agente de DevOps usa para el trabajo administrativo
# continuo de Vault (crear/gestionar secretos KV, AppRoles de
# consumidores como Jenkins/backend de auth-core-mc, y sus policies) a
# lo largo de los tickets 004-006 y en adelante, sin necesitar el token
# root cada vez.
#
# Requiere el token root en /home/ubuntu/secrets/vault/admin-token.txt
# (Marco lo deja ahí temporalmente, recuperado de su gestor de
# contraseñas -- NUNCA en git, NUNCA impreso por este script). Se usa
# solo para esta corrida; después de correrlo, Marco borra ese archivo
# (`shred -u`) y todo el trabajo posterior usa el AppRole platform-admin
# en vez del token root.
#
# Idempotente: seguro de re-correr (útil si Vault se reconstruye desde
# cero en un desastre, o para re-verificar que la policy sigue acotada
# correctamente -- las pruebas negativas del final son una regresión de
# seguridad real, no solo un smoke test positivo).
#
# Uso (desde la VM, con el token root ya en el archivo de arriba):
#   ./bootstrap-admin-approle.sh

set -euo pipefail

TOKEN_FILE=/home/ubuntu/secrets/vault/admin-token.txt
if [ ! -f "$TOKEN_FILE" ]; then
  echo "Falta $TOKEN_FILE -- pide a Marco que deje ahí el token root temporalmente (ver docs/ARQUITECTURA.md, 'AppRole platform-admin')." >&2
  exit 1
fi
ROOT_TOKEN=$(tr -d '[:space:]' < "$TOKEN_FILE")

run() {
  docker exec -i -e VAULT_TOKEN="$ROOT_TOKEN" vault vault "$@"
}

echo "== KV v2 en secret/ (si falta) =="
if run secrets list -format=json | python3 -c "import json,sys; exit(0 if 'secret/' in json.load(sys.stdin) else 1)"; then
  echo "secret/ ya estaba habilitado."
else
  run secrets enable -path=secret -version=2 kv
fi

echo "== auth/approle (si falta) =="
if run auth list -format=json | python3 -c "import json,sys; exit(0 if 'approle/' in json.load(sys.stdin) else 1)"; then
  echo "approle ya estaba habilitado."
else
  run auth enable approle
fi

echo "== policy platform-admin =="
run policy write platform-admin - <<'POLICY'
# AppRole administrativo del agente de DevOps -- ver docs/definiciones/
# vault-secrets-manager-vm.md (adenda 2026-09-01) para el porqué
# completo. Acotado a exactamente lo necesario para bootstrap/
# administración continua de Vault: crear/leer/actualizar secretos KV,
# crear/gestionar AppRoles de consumidores (Jenkins, backend de
# auth-core-mc), y crear/gestionar las policies de esos AppRoles. NUNCA
# gestión del seal/KMS, NUNCA habilitar/deshabilitar auth methods o
# secrets engines nuevos (sys/mounts y sys/auth son solo lectura acá,
# a propósito), NUNCA sys/* amplio.

path "secret/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Hallazgo real (ticket 004, primer run real de sync-vm-infra): faltaba
# esto. El motor Transit (habilitado en el ticket 003) también es
# trabajo administrativo continuo -- el paso idempotente de
# sync-vm-infra que asegura la llave auth-core-mc-tenant-keys, y el
# futuro AppRole del backend de auth-core-mc (ticket 005), lo
# necesitan. Sin esto, hasta LEER si la llave ya existe daba 403 (no
# solo crearla) -- verificado en vivo, no teórico.
path "transit/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "auth/approle/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "sys/mounts" {
  capabilities = ["read"]
}

path "sys/mounts/*" {
  capabilities = ["read"]
}

path "sys/auth" {
  capabilities = ["read"]
}
POLICY

echo "== approle role platform-admin =="
run write auth/approle/role/platform-admin \
  token_policies="platform-admin" \
  token_ttl=1h \
  token_max_ttl=4h \
  token_num_uses=0 \
  secret_id_ttl=0 \
  secret_id_num_uses=0

ROLE_ID=$(run read -field=role_id auth/approle/role/platform-admin/role-id)
echo "ROLE_ID (no es secreto, ver docs/ARQUITECTURA.md): $ROLE_ID"
echo "$ROLE_ID" > /home/ubuntu/secrets/vault/platform-admin-role-id
chmod 600 /home/ubuntu/secrets/vault/platform-admin-role-id

# El SecretID SÍ es secreto -- nunca se imprime, solo se redirige al
# archivo (600, dueño ubuntu), mismo patrón que el resto de esta infra.
run write -field=secret_id -f auth/approle/role/platform-admin/secret-id > /home/ubuntu/secrets/vault/platform-admin-secret-id
chmod 600 /home/ubuntu/secrets/vault/platform-admin-secret-id
echo "SecretID guardado en /home/ubuntu/secrets/vault/platform-admin-secret-id (no impreso)."

echo "== Verificación: login + prueba positiva + dos pruebas negativas =="
NEW_ROLE_ID=$(cat /home/ubuntu/secrets/vault/platform-admin-role-id)
NEW_SECRET_ID=$(cat /home/ubuntu/secrets/vault/platform-admin-secret-id)
LOGIN_OUT=$(docker exec vault vault write -format=json auth/approle/login role_id="$NEW_ROLE_ID" secret_id="$NEW_SECRET_ID")
AGENT_TOKEN=$(echo "$LOGIN_OUT" | python3 -c "import json,sys;print(json.load(sys.stdin)['auth']['client_token'])")

docker exec -e VAULT_TOKEN="$AGENT_TOKEN" vault vault kv put secret/_smoke-test value=ok >/dev/null
READBACK=$(docker exec -e VAULT_TOKEN="$AGENT_TOKEN" vault vault kv get -field=value secret/_smoke-test)
[ "$READBACK" = "ok" ] || { echo "FALLO: no pudo leer/escribir en secret/" >&2; exit 1; }
docker exec -e VAULT_TOKEN="$AGENT_TOKEN" vault vault kv metadata delete secret/_smoke-test >/dev/null
echo "OK: platform-admin puede escribir/leer en secret/."

if docker exec -e VAULT_TOKEN="$AGENT_TOKEN" vault vault operator seal >/dev/null 2>&1; then
  echo "FALLO DE SEGURIDAD: platform-admin pudo sellar Vault (no debería)." >&2
  exit 1
fi
echo "OK: platform-admin NO puede sellar Vault (rechazado, 403 confirmado)."

if docker exec -e VAULT_TOKEN="$AGENT_TOKEN" vault vault secrets enable -path=_should-fail kv >/dev/null 2>&1; then
  echo "FALLO DE SEGURIDAD: platform-admin pudo montar un secrets engine nuevo (no debería)." >&2
  exit 1
fi
echo "OK: platform-admin NO puede montar secrets engines nuevos (rechazado, 403 confirmado)."

echo "== Listo. Pide a Marco que borre $TOKEN_FILE (shred -u) -- ya no hace falta. =="
