#!/usr/bin/env bash
# Ticket 002, punto 7 (con el ajuste de Marco de "máxima automatización":
# UN script que se corre una sola vez por proyecto, no una receta de
# pasos manuales). Dado un repo de GitHub recién creado con solo su rama
# default (normalmente "main"), deja las 3 ramas persistentes
# (dev/qa/prod) + la branch protection que ya usa auth-core-mc, listas
# para que Jenkins (Organization Folder de 64bitstudio) las descubra.
#
# Uso:
#   ./deploy/scripts/bootstrap-project-branches.sh <nombre-del-repo>
#
# Ej.: ./deploy/scripts/bootstrap-project-branches.sh mail-core-mc
#
# Requiere: gh CLI autenticado (gh auth status) con permiso de admin
# sobre el repo (para branch protection y para cambiar la rama default).
#
# Idempotente: si una rama ya existe, no la vuelve a crear; si la
# protección ya está aplicada, "gh api --method PUT" simplemente la
# reafirma (sin efecto destructivo).
#
# Qué NO hace este script (a propósito, ver docs/ARQUITECTURA.md runbook
# "conectar un proyecto nuevo" para el resto de los pasos):
#   - No crea el Jenkinsfile del proyecto (paso de código, no de infra
#     GitHub).
#
# Webhook GitHub -> Jenkins (punto 6): SÍ lo crea este script, por API,
# con las credenciales de "gh" (que ya funcionan de sobra para todo lo
# demás aquí). Ajuste real sobre el plan original: se intentó primero
# que el plugin "github" de Jenkins lo gestionara solo, a nivel de
# organización (JCasC, gitHubPluginConfig.manageHooks) -- funciona para
# ACTUALIZAR un webhook que ya existe, pero falla con "401 Bad
# credentials" al intentar CREAR uno nuevo (el cliente REST interno del
# plugin, librería github-api, no acepta el credential tipo usuario+PAT
# de la misma forma que sí lo acepta git para checkout/push -- ver
# docs/ARQUITECTURA.md para el log real y el diagnóstico completo). Se
# abandonó esa vía por frágil y se volvió a este script, que sí es
# confiable y mantiene el principio de "un solo comando".

set -euo pipefail

OWNER="64bitstudio"
REPO="${1:?uso: bootstrap-project-branches.sh <nombre-del-repo>}"

if ! gh auth status >/dev/null 2>&1; then
  echo "❌ gh CLI no autenticado (gh auth status falló)." >&2
  exit 1
fi

echo "== Repo: ${OWNER}/${REPO} =="
DEFAULT_BRANCH=$(gh api "repos/${OWNER}/${REPO}" --jq '.default_branch')
echo "Rama default actual: ${DEFAULT_BRANCH}"
BASE_SHA=$(gh api "repos/${OWNER}/${REPO}/git/ref/heads/${DEFAULT_BRANCH}" --jq '.object.sha')
echo "SHA base (HEAD de ${DEFAULT_BRANCH}): ${BASE_SHA}"

branch_exists() {
  gh api "repos/${OWNER}/${REPO}/branches/$1" >/dev/null 2>&1
}

create_branch_if_missing() {
  local branch="$1"
  if branch_exists "$branch"; then
    echo "Rama '${branch}' ya existe -- se deja igual (no se mueve su HEAD)."
  else
    echo "Creando rama '${branch}' desde ${BASE_SHA}..."
    gh api "repos/${OWNER}/${REPO}/git/refs" \
      -f "ref=refs/heads/${branch}" \
      -f "sha=${BASE_SHA}" \
      >/dev/null
  fi
}

# 1. dev, qa, prod -- las 3 ramas persistentes (ver memoria de equipo
#    saas-paas-cores-strategy: feature/NNN -> dev -> qa -> prod, fijo
#    para todo core).
create_branch_if_missing "dev"
create_branch_if_missing "qa"
create_branch_if_missing "prod"

# 2. dev pasa a ser la rama default del repo (mismo patrón que
#    auth-core-mc) -- así un PR de feature/NNN apunta a dev por defecto
#    sin que nadie tenga que cambiarlo a mano cada vez.
if [ "$DEFAULT_BRANCH" != "dev" ]; then
  echo "Cambiando la rama default a 'dev'..."
  gh api --method PATCH "repos/${OWNER}/${REPO}" -f default_branch=dev >/dev/null
else
  echo "La rama default ya es 'dev'."
fi

# 3. Branch protection idéntica a la que ya corre en dev/qa/prod de
#    auth-core-mc (confirmada por API el 2026-08-31, ver docs/
#    ARQUITECTURA.md) -- el check requerido es el que publica Jenkins en
#    cada build de un Multibranch Pipeline
#    ("continuous-integration/jenkins/branch"), no un job de GitHub
#    Actions (ya no existe para ningún core).
PROTECTION_JSON=$(cat <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["continuous-integration/jenkins/branch"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": false,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 0
  },
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": true,
  "lock_branch": false,
  "allow_fork_syncing": false
}
JSON
)

for branch in dev qa prod; do
  echo "Aplicando branch protection a '${branch}'..."
  echo "$PROTECTION_JSON" | gh api --method PUT "repos/${OWNER}/${REPO}/branches/${branch}/protection" --input - >/dev/null
done

# 4. Webhook GitHub -> Jenkins (punto 6) -- mismo patrón que se usó a
#    mano para auth-core-mc (evento push, JSON content-type, sin
#    verificación SSL especial -- TLS real de Let's Encrypt). Idempotente:
#    busca por URL antes de crear, nunca duplica.
JENKINS_HOOK_URL="https://jenkins.64bitstudio.com/github-webhook/"
echo "Verificando webhook GitHub -> Jenkins..."
EXISTING_HOOK_ID=$(gh api "repos/${OWNER}/${REPO}/hooks" --jq ".[] | select(.config.url==\"${JENKINS_HOOK_URL}\") | .id" | head -1)

if [ -n "$EXISTING_HOOK_ID" ]; then
  echo "Webhook a Jenkins ya existe (id ${EXISTING_HOOK_ID})."
else
  echo "Creando webhook GitHub -> Jenkins..."
  HOOK_JSON=$(cat <<JSON
{
  "name": "web",
  "active": true,
  "events": ["push"],
  "config": {
    "url": "${JENKINS_HOOK_URL}",
    "content_type": "json",
    "insecure_ssl": "0"
  }
}
JSON
)
  echo "$HOOK_JSON" | gh api --method POST "repos/${OWNER}/${REPO}/hooks" --input - >/dev/null
  EXISTING_HOOK_ID=$(gh api "repos/${OWNER}/${REPO}/hooks" --jq ".[] | select(.config.url==\"${JENKINS_HOOK_URL}\") | .id" | head -1)
fi

# Verificación real (no solo que la API de GitHub aceptó el POST): un
# ping real al webhook y confirmar que Jenkins respondió 200.
echo "Pingeando el webhook para confirmar que Jenkins responde..."
gh api --method POST "repos/${OWNER}/${REPO}/hooks/${EXISTING_HOOK_ID}/pings" >/dev/null
sleep 3
PING_STATUS=$(gh api "repos/${OWNER}/${REPO}/hooks/${EXISTING_HOOK_ID}" --jq '.last_response.code')
if [ "$PING_STATUS" = "200" ]; then
  echo "Webhook confirmado -- Jenkins respondió 200 al ping real."
else
  echo "⚠️  El último response code del webhook es '${PING_STATUS}', no 200 -- revisar a mano (gh api repos/${OWNER}/${REPO}/hooks/${EXISTING_HOOK_ID})." >&2
fi

echo ""
echo "== Listo =="
echo "dev/qa/prod creadas (o ya existentes) + branch protection + webhook a Jenkins, todo en esta sola corrida."
echo "Pendiente (única acción manual real, ver el comentario al inicio de este script):"
echo "  1. Agregar el Jenkinsfile del proyecto (usando @Library('platform') corePipeline(...))."
echo "     En cuanto se pushee, el webhook recién creado dispara el build real -- sin rescan manual."
