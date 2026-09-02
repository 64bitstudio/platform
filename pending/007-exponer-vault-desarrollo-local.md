# 007 — Exponer Vault para desarrollo local (retiro del Vault local de la Mac)

## Objetivo
Exponer el motor Transit de la Vault de la VM (instalada en el ticket
003) en un subdominio público (`vault.64bitstudio.com`), con una AppRole
propia de mínimo privilegio para desarrollo local, para que
`auth-core-mc/pending/0XX-retirar-vault-local.md` pueda retirar el Vault
local de `~/dev-infra` sin perder la funcionalidad de cifrado por sobres
en desarrollo local. Motivado por Marco: "quitarlo [el Vault local] y
apuntar el dev local a la Vault de la VM".

Este ticket toca **solo el lado de Vault/infra** (este repo, `platform`);
el ticket correspondiente de `auth-core-mc` cubre el retiro del Vault
local y el cambio de `application.properties`.

## Alcance

**Incluye:**
- Vhost de nginx `vault.64bitstudio.com` -- mismo patrón de transporte
  que el resto de la infra (nginx TLS -> Traefik interno -> contenedor),
  pero **sin Basic Auth compartido** (a diferencia de
  sonarqube/traefik/portainer) -- Vault ya tiene su propio sistema de
  autenticación (AppRole) diseñado para exposición controlada. En su
  lugar: allowlist de nginx a las 3 rutas exactas que el consumidor
  legítimo (desarrollo local) necesita, más rate limiting sobre el único
  endpoint de login expuesto. Ver `nginx/vault.conf` para el análisis
  completo.
- Labels de Traefik + red `edge` en `deploy/vm-infra/vault/docker-compose.yml`.
- Certificado Let's Encrypt real para `vault.64bitstudio.com` (requiere
  que Marco cree el registro DNS primero, mismo patrón que los demás
  subdominios).
- AppRole nueva `auth-core-mc-local-dev` -- mismo alcance exacto que
  `auth-core-mc-backend` (ticket 005: solo encrypt/decrypt sobre
  `auth-core-mc-tenant-keys`), pero **credencial separada y revocable
  independientemente** de la que usan los ambientes desplegados
  (DEV/QA/PROD). RoleID/SecretID entregados a Marco vía su propio
  `backend/.env` local (nunca impresos en ningún log).
- Verificación real: login AppRole + encrypt/decrypt reales desde fuera
  de la VM (no solo desde dentro), y las mismas pruebas negativas ya
  usadas en el ticket 005 (403 en rutas fuera de policy).

**No incluye:**
- Cambiar cómo el backend desplegado (DEV/QA/PROD) habla con Vault --
  sigue siendo por la red interna `vm-infra` (`http://vault:8200`),
  nunca por este subdominio público.
- Retirar el Vault local de la Mac ni tocar `application.properties` de
  `auth-core-mc` -- eso es el ticket correspondiente de ese repo, y
  depende de que este ticket esté cerrado primero.

## VoBo requerido antes de aplicar en definitivo
Exponer Vault a internet es una superficie de ataque nueva real, distinta
de sumar un subdominio más detrás de Basic Auth. Los archivos de este
ticket (vhost, labels de Traefik, paso de CI) se preparan y se prueban en
rama de feature, **pero no se hace push de esa rama (lo que dispararía
`sync-vm-infra` y aplicaría el cambio en la VM real, `branches: ["**"]`)
hasta VoBo explícito de Marco**, relayado por el orquestador. No es
suficiente con "resuelve el problema original" -- se pide confirmación
aparte.

## Criterios de aceptación
- Dado el vhost desplegado, cuando se golpea cualquier ruta fuera del
  allowlist (`/ui`, `/v1/sys/health`, etc.) desde fuera de la VM, entonces
  nginx responde 404 sin llegar a Vault -- verificado en vivo.
- Dado el AppRole `auth-core-mc-local-dev`, cuando se usa desde fuera de
  la VM (no solo `docker exec`), entonces login + encrypt + decrypt
  funcionan de punta a punta -- verificado en vivo, no solo desde dentro
  de la red `vm-infra`.
- Dado un intento con esa AppRole de leer `secret/jenkins` o rotar la
  llave, entonces Vault rechaza con 403 -- mismo patrón de prueba negativa
  que el ticket 005.
- Dado que el `SecretID` se filtrara, entonces el daño queda acotado a
  Transit sobre `auth-core-mc-tenant-keys`, y es revocable sin afectar al
  AppRole `auth-core-mc-backend` de los ambientes desplegados.

## Hecho
_Pendiente -- bloqueado en espera de VoBo explícito de Marco sobre la
exposición pública antes de aplicar el vhost/certificado/labels en la VM
real. AppRole `auth-core-mc-local-dev` ya creada y verificada (positiva +
2 negativas) -- eso NO expone nada nuevo (es administración interna de
Vault vía SSH), así que se ejecutó sin esperar ese VoBo._
