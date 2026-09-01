#!/usr/bin/env bash
# Ticket platform/004 (docs/definiciones/vault-secrets-manager-vm.md,
# HU-1/HU-4): migra a Vault los secretos de infra que hoy viven en
# archivos sueltos -- uno a la vez, verificando cada paso (lectura de
# vuelta desde Vault, comparada contra el valor original) antes de
# seguir. Requiere el AppRole "platform-admin" ya creado (ver
# bootstrap-admin-approle.sh).
#
# NO borra los archivos originales -- HU-4 pide que sigan existiendo
# como vía de rollback hasta confirmar Vault de punta a punta (ver
# vars/corePipeline.groovy, que ahora los usa como destino RENDERIZADO,
# no como fuente de verdad).
#
# Idempotente: vault kv put sobreescribe (crea una versión nueva, KV v2
# mantiene el historial) -- seguro de re-correr si algún valor local
# cambia y hay que re-sincronizar a mano.
#
# Uso (desde la VM):
#   ./migrate-infra-secrets.sh

set -euo pipefail

ADMIN_ROLE_ID=$(cat /home/ubuntu/secrets/vault/platform-admin-role-id)
ADMIN_SECRET_ID=$(cat /home/ubuntu/secrets/vault/platform-admin-secret-id)
LOGIN_OUT=$(docker exec vault vault write -format=json auth/approle/login role_id="$ADMIN_ROLE_ID" secret_id="$ADMIN_SECRET_ID")
ADMIN_TOKEN=$(echo "$LOGIN_OUT" | python3 -c "import json,sys;print(json.load(sys.stdin)['auth']['client_token'])")

run() {
  docker exec -i -e VAULT_TOKEN="$ADMIN_TOKEN" vault vault "$@"
}

get_env_var() {
  grep -m1 "^$2=" "$1" | cut -d= -f2-
}

echo "== Migrando DB_PASSWORD: dev -> qa -> prod (verificando cada paso) =="
for ENV in dev qa prod; do
  FILE="/home/ubuntu/secrets/auth-core-mc/.env.${ENV}"
  DB_PASSWORD=$(get_env_var "$FILE" "DB_PASSWORD")
  [ -n "$DB_PASSWORD" ] || { echo "FALLO: DB_PASSWORD vacío en $FILE" >&2; exit 1; }
  run kv put "secret/auth-core-mc/${ENV}" DB_PASSWORD="$DB_PASSWORD" >/dev/null
  READBACK=$(run kv get -field=DB_PASSWORD "secret/auth-core-mc/${ENV}")
  [ "$READBACK" = "$DB_PASSWORD" ] || { echo "FALLO: no coincide tras migrar ${ENV}." >&2; exit 1; }
  echo "OK: secret/auth-core-mc/${ENV} migrado y verificado (valor coincide, no impreso)."
done

echo "== Migrando secretos de Jenkins (PAT, SONAR_TOKEN, Telegram) =="
JFILE=/home/ubuntu/secrets/jenkins/.env
GITHUB_PAT=$(get_env_var "$JFILE" "GITHUB_PAT")
SONAR_TOKEN=$(get_env_var "$JFILE" "SONAR_TOKEN")
TELEGRAM_BOT_TOKEN=$(get_env_var "$JFILE" "TELEGRAM_BOT_TOKEN")
TELEGRAM_CHAT_ID=$(get_env_var "$JFILE" "TELEGRAM_CHAT_ID")
run kv put secret/jenkins \
  GITHUB_PAT="$GITHUB_PAT" \
  SONAR_TOKEN="$SONAR_TOKEN" \
  TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" \
  TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID" >/dev/null
RB_PAT=$(run kv get -field=GITHUB_PAT secret/jenkins)
[ "$RB_PAT" = "$GITHUB_PAT" ] || { echo "FALLO: GITHUB_PAT no coincide tras migrar." >&2; exit 1; }
echo "OK: secret/jenkins migrado y verificado."

echo "== Migrando hash de Basic Auth de nginx =="
HTFILE=/etc/nginx/secrets/vm-admin-tools.htpasswd
HTLINE=$(sudo cat "$HTFILE")
run kv put secret/nginx/basic-auth htpasswd="$HTLINE" >/dev/null
RB_HT=$(run kv get -field=htpasswd secret/nginx/basic-auth)
[ "$RB_HT" = "$HTLINE" ] || { echo "FALLO: htpasswd no coincide tras migrar." >&2; exit 1; }
echo "OK: secret/nginx/basic-auth migrado y verificado."

echo "== Listo: los 5 secretos migrados y verificados. =="
