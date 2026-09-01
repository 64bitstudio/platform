#!/bin/sh
# Ticket platform/006 (docs/definiciones/vault-secrets-manager-vm.md,
# HU-9): decodifica GITHUB_APP_PRIVATE_KEY_B64 (base64, una sola línea
# -- seguro para la interpolación de texto que hace Docker Compose
# ANTES de parsear su propio YAML) a GITHUB_APP_PRIVATE_KEY (la llave
# PEM real, multilínea) DENTRO del contenedor, antes de que Jenkins
# arranque -- así JCasC (casc/jenkins.yaml, credential "github-app")
# la lee ya como texto real vía sustitución de variable de entorno de
# Jenkins/JCasC (que sí soporta valores multilínea, a diferencia de la
# sustitución de Compose).
#
# Hallazgo real que motivó esto: pasar la llave PEM multilínea
# directamente como valor de una variable de entorno en
# docker-compose.yml rompía la estructura YAML del propio compose file
# tras la sustitución de texto -- el contenedor fallaba con "exit code
# 127" y fragmentos de la llave aparecían como si Compose intentara
# ejecutarlos como comandos.
set -e

if [ -n "${GITHUB_APP_PRIVATE_KEY_B64:-}" ]; then
    export GITHUB_APP_PRIVATE_KEY=$(echo "$GITHUB_APP_PRIVATE_KEY_B64" | base64 -d)
fi

exec /usr/bin/tini -- "$@"
