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

Cerrado 2026-09-02. Todos los criterios verificados con evidencia real
-- ver `docs/ARQUITECTURA.md`, sección "Ticket 007", para el detalle
completo (incluido un incidente real de proceso -- git -- durante el
ticket, reportado y corregido en vivo, no ocultado).

- **VoBo explícito de Marco** obtenido antes de dejar el vhost/certificado
  en definitivo, relayado por el orquestador -- tal como pedía este
  ticket.
- **Vhost `vault.64bitstudio.com`** con allowlist de 3 rutas exactas
  (login AppRole + encrypt/decrypt de `auth-core-mc-tenant-keys`), sin
  Basic Auth compartido, más rate limiting (60r/m, ajustado desde el
  5r/m inicial -- ver el incidente de git en ARQUITECTURA.md) sobre el
  login. Certificado real de Let's Encrypt emitido tras que Marco creara
  el registro DNS vía la API de Cloudflare.
- **AppRole `auth-core-mc-local-dev`** creada y verificada (positiva + 2
  negativas reales: 403 en `secret/jenkins`, 403 al rotar la llave).
  RoleID (no-secreto) y SecretID entregados a `auth-core-mc/backend/.env`
  de Marco, nunca impresos.
- **Verificado en vivo desde fuera de la VM** (criterio de aceptación
  explícito, "no solo desde dentro de vm-infra"): las rutas fuera del
  allowlist responden 404 sin llegar a Vault; login con credenciales
  inválidas sí llega a Vault (400 real); login + encrypt + decrypt reales
  con las credenciales de `auth-core-mc-local-dev` -- round-trip exitoso.
- **Incidente real de proceso, reportado antes de seguir adelante**: este
  trabajo terminó fusionado en `main` por accidente vía el PR #25 (un PR
  de documentación no relacionado), en vez de vía el PR #28 dedicado a
  este ticket -- por una condición de carrera de `git commit --amend` en
  un working directory compartido con otro trabajo concurrente de la
  misma sesión. El agente lo detectó, lo reportó de inmediato sin
  intentar ocultarlo, y lo corrigió (`git branch -f`, sin tocar contenido
  ajeno) antes de cualquier otro push. Ver ARQUITECTURA.md para el
  detalle completo y el candidato a hook de `dev-org-hooks-suite` que
  salió de este hallazgo.
- Retiro efectivo del Vault local de la Mac y su verificación end-to-end
  del lado de la aplicación: `auth-core-mc/pending/051` (o `done/051` si
  ya cerró para cuando se lea esto).
