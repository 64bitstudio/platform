#!/usr/bin/env bash
# Ticket platform/004 (docs/definiciones/vault-secrets-manager-vm.md,
# HU-3): AppRole "jenkins-infra" -- solo lectura, solo los paths de
# secretos de infra que vars/corePipeline.groovy necesita en tiempo de
# deploy (DB_PASSWORD por proyecto/ambiente, secretos propios de
# Jenkins, hash de Basic Auth de nginx). Requiere el AppRole
# "platform-admin" ya creado (ver bootstrap-admin-approle.sh) -- no el
# token root.
#
# Idempotente: seguro de re-correr. Si el ROLE_ID cambia (recreación
# desde cero), hay que actualizar JENKINS_VAULT_APPROLE_ROLE_ID en
# vars/corePipeline.groovy también -- el script lo imprime al final
# como recordatorio.
#
# Uso (desde la VM):
#   ./bootstrap-jenkins-approle.sh

set -euo pipefail

ADMIN_ROLE_ID=$(cat /home/ubuntu/secrets/vault/platform-admin-role-id)
ADMIN_SECRET_ID=$(cat /home/ubuntu/secrets/vault/platform-admin-secret-id)
LOGIN_OUT=$(docker exec vault vault write -format=json auth/approle/login role_id="$ADMIN_ROLE_ID" secret_id="$ADMIN_SECRET_ID")
ADMIN_TOKEN=$(echo "$LOGIN_OUT" | python3 -c "import json,sys;print(json.load(sys.stdin)['auth']['client_token'])")

run() {
  docker exec -i -e VAULT_TOKEN="$ADMIN_TOKEN" vault vault "$@"
}

echo "== policy jenkins-infra (solo lectura, paths acotados) =="
run policy write jenkins-infra - <<'POLICY'
# AppRole de Jenkins (ticket platform/004, HU-3) -- solo lectura, solo
# los paths de secretos de infra que corePipeline.groovy necesita en
# tiempo de deploy. "+" es un wildcard de UN SOLO segmento (no
# recursivo) -- cubre cualquier proyecto actual o futuro que use la
# Shared Library (auth-core-mc, mail-core-mc, ...) sin tocar esta
# policy por proyecto nuevo, pero SOLO para los 3 nombres de ambiente
# literales (dev/qa/prod) -- cualquier otro segmento ahí (ej.
# "staging") queda fuera a propósito.
path "secret/data/+/dev" {
  capabilities = ["read"]
}
path "secret/data/+/qa" {
  capabilities = ["read"]
}
path "secret/data/+/prod" {
  capabilities = ["read"]
}
path "secret/data/jenkins" {
  capabilities = ["read"]
}
path "secret/data/nginx/basic-auth" {
  capabilities = ["read"]
}
POLICY

echo "== approle role jenkins-infra =="
run write auth/approle/role/jenkins-infra \
  token_policies="jenkins-infra" \
  token_ttl=15m \
  token_max_ttl=30m \
  token_num_uses=0 \
  secret_id_ttl=0 \
  secret_id_num_uses=0

ROLE_ID=$(run read -field=role_id auth/approle/role/jenkins-infra/role-id)
echo "$ROLE_ID" > /home/ubuntu/secrets/vault/jenkins-infra-role-id
chmod 644 /home/ubuntu/secrets/vault/jenkins-infra-role-id
echo "ROLE_ID de jenkins-infra (no es secreto): $ROLE_ID"
echo "-> Si este valor difiere del que ya vive en vars/corePipeline.groovy (JENKINS_VAULT_APPROLE_ROLE_ID), hay que actualizarlo ahí."

# El SecretID SÍ es secreto -- se agrega a /home/ubuntu/secrets/jenkins/.env
# (mismo archivo que el resto de secretos de Jenkins), nunca impreso.
SECRET_ID=$(run write -field=secret_id -f auth/approle/role/jenkins-infra/secret-id)
ENVFILE=/home/ubuntu/secrets/jenkins/.env
if grep -q '^VAULT_JENKINS_SECRET_ID=' "$ENVFILE" 2>/dev/null; then
  sed -i "s#^VAULT_JENKINS_SECRET_ID=.*#VAULT_JENKINS_SECRET_ID=${SECRET_ID}#" "$ENVFILE"
  echo "VAULT_JENKINS_SECRET_ID actualizado en $ENVFILE."
else
  printf 'VAULT_JENKINS_SECRET_ID=%s\n' "$SECRET_ID" >> "$ENVFILE"
  echo "VAULT_JENKINS_SECRET_ID agregado a $ENVFILE."
fi

echo "== Verificación: login + prueba positiva + 3 pruebas negativas =="
JROLE_ID=$(cat /home/ubuntu/secrets/vault/jenkins-infra-role-id)
JLOGIN=$(docker exec vault vault write -format=json auth/approle/login role_id="$JROLE_ID" secret_id="$SECRET_ID")
JTOKEN=$(echo "$JLOGIN" | python3 -c "import json,sys;print(json.load(sys.stdin)['auth']['client_token'])")

docker exec -e VAULT_TOKEN="$JTOKEN" vault vault kv get -field=DB_PASSWORD secret/auth-core-mc/dev >/dev/null
echo "OK: jenkins-infra puede leer secret/auth-core-mc/dev."

if docker exec -e VAULT_TOKEN="$JTOKEN" vault vault kv get secret/auth-core-mc/staging >/dev/null 2>&1; then
  echo "FALLO DE SEGURIDAD: pudo leer un ambiente fuera de dev/qa/prod." >&2; exit 1
fi
echo "OK: rechazado un ambiente fuera de dev/qa/prod (403 real)."

if docker exec -e VAULT_TOKEN="$JTOKEN" vault vault kv put secret/auth-core-mc/dev DB_PASSWORD=hackeado >/dev/null 2>&1; then
  echo "FALLO DE SEGURIDAD: pudo escribir (debería ser solo lectura)." >&2; exit 1
fi
echo "OK: rechazada la escritura (403 real, solo lectura)."

if docker exec -e VAULT_TOKEN="$JTOKEN" vault vault read auth/approle/role/platform-admin/secret-id >/dev/null 2>&1; then
  echo "FALLO DE SEGURIDAD: pudo leer datos administrativos de AppRole." >&2; exit 1
fi
echo "OK: rechazado el acceso a datos administrativos de AppRole (403 real)."

echo "== Listo: AppRole jenkins-infra creado y verificado. =="
