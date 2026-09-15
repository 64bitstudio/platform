# 008 — Traefik: `forwardedHeaders.trustedIPs` para el `X-Forwarded-Proto` real de nginx

## Objetivo
Ticket retroactivo. Hallazgo real durante la verificación en vivo de galgoth-studio#093 (Pantalla "Usuario", "Conectar" cuenta de Google real) — VoBo explícito de Marco vía `AskUserQuestion` antes de tocar infra compartida.

nginx (host, único punto de entrada TLS público, ver `deploy/vm-infra/nginx/`) ya manda `X-Forwarded-Proto: https` correctamente a Traefik. Pero el entrypoint `web` de Traefik (`deploy/vm-infra/traefik/config/traefik.yml`, ticket `049`) no tenía `forwardedHeaders.trustedIPs` configurado — sin eso, Traefik no confía en ningún header reenviado de nadie y lo sobreescribe con el esquema de SU PROPIA conexión entrante (`http`, porque nginx→Traefik puertas adentro es HTTP plano en `127.0.0.1:8000`) antes de reenviar al contenedor de cada servicio.

Esto no es específico de auth-core-mc: **cualquier** servicio detrás de este Traefik que construya una URL absoluta a partir del request recibido (esquema/host) hereda el mismo esquema incorrecto. El caso real que lo expuso: `auth-core-mc` construye el `redirect_uri` de OAuth2 a partir del request (`{baseUrl}/login/oauth2/code/{registrationId}`, ver `TenantAwareClientRegistrationRepository`), y Google lo rechazaba con `redirect_uri_mismatch` por traer `http://` en vez de `https://` — confirmado con un `curl` directo al contenedor (con el header puesto a mano SÍ funciona, ver auth-core-mc#068, que ya trae el fix del lado de Spring pero necesitaba este fix de Traefik para completarse en la topología real).

## Criterios de aceptación
- `traefik.yml`: `entryPoints.web.forwardedHeaders.trustedIPs` incluye la(s) IP(s) desde las que Traefik observa de verdad la conexión de nginx — el único origen que puede alcanzar ese entrypoint (ver `docker-compose.yml`: publicado solo en loopback).
- Verificado en vivo: un `curl` real contra `https://auth-dev.64bitstudio.com/oauth2/authorization/...` (sin headers manuales, a través de nginx→Traefik→contenedor) produce un `redirect_uri` con esquema `https://`.
- Verificado en vivo contra dev, como parte de la verificación de galgoth-studio#093: "Conectar" con una cuenta de Google real ya no falla con `redirect_uri_mismatch`.

## Hecho
**Primera vuelta** (PR #31, mergeada): `trustedIPs: ["127.0.0.1/32"]` — la intención razonable dado que el puerto se publica como `127.0.0.1:8000:8000`. `docker compose up -d` (el paso ya existente en `.github/workflows/ci.yml`) no recreó el contenedor Traefik solo por el cambio en el archivo de config bind-montado (el hash de servicio de Compose no cambia); se forzó un recreate manual vía SSH (`docker compose -f deploy/vm-infra/traefik/docker-compose.yml up -d --force-recreate traefik`). **Verificado con un `curl` real y NO funcionó** — `redirect_uri` seguía en `http://`.

**Segunda vuelta, hallazgo real** (mismo ticket, commit adicional, con VoBo explícito de Marco antes de ampliar `trustedIPs` — el permiso de la herramienta bloqueó el primer intento del ajuste por ser un cambio de límite de confianza, correctamente): Docker hace el DNAT del puerto publicado vía iptables antes de que el paquete llegue al contenedor — Traefik ve la conexión de nginx como originada en la gateway de la red `edge` (`172.20.0.1`, confirmado con `docker network inspect edge`), nunca literalmente `127.0.0.1`, aunque desde el HOST sí sea loopback. Se agregó `172.20.0.1/32` a `trustedIPs` (se dejan ambas IPs: `127.0.0.1/32` documenta la intención real, `172.20.0.1/32` es la que hace falta con la implementación actual de Docker en esta VM). Recreate manual de Traefik de nuevo.

CI verde (ver PRs #31 y el commit adicional). Verificado en vivo: `curl` directo contra `auth-dev.64bitstudio.com` produce `redirect_uri=https://...`, y el flujo completo de "Conectar" con una cuenta de Google real en galgoth-studio#093 completa el consentimiento sin `redirect_uri_mismatch`.

No rompe compatibilidad — estrictamente aditivo, y ambas IPs siguen siendo exactamente el mismo origen de confianza (nginx, en el mismo host, enrutado por el propio Docker) que ya podía alcanzar este entrypoint — solo corrige cuál de las dos representaciones de ese origen Traefik observa de verdad.
