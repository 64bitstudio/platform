# 008 — Traefik: `forwardedHeaders.trustedIPs` para el `X-Forwarded-Proto` real de nginx

## Objetivo
Ticket retroactivo. Hallazgo real durante la verificación en vivo de galgoth-studio#093 (Pantalla "Usuario", "Conectar" cuenta de Google real) — VoBo explícito de Marco vía `AskUserQuestion` antes de tocar infra compartida.

nginx (host, único punto de entrada TLS público, ver `deploy/vm-infra/nginx/`) ya manda `X-Forwarded-Proto: https` correctamente a Traefik. Pero el entrypoint `web` de Traefik (`deploy/vm-infra/traefik/config/traefik.yml`, ticket `049`) no tenía `forwardedHeaders.trustedIPs` configurado — sin eso, Traefik no confía en ningún header reenviado de nadie y lo sobreescribe con el esquema de SU PROPIA conexión entrante (`http`, porque nginx→Traefik puertas adentro es HTTP plano en `127.0.0.1:8000`) antes de reenviar al contenedor de cada servicio.

Esto no es específico de auth-core-mc: **cualquier** servicio detrás de este Traefik que construya una URL absoluta a partir del request recibido (esquema/host) hereda el mismo esquema incorrecto. El caso real que lo expuso: `auth-core-mc` construye el `redirect_uri` de OAuth2 a partir del request (`{baseUrl}/login/oauth2/code/{registrationId}`, ver `TenantAwareClientRegistrationRepository`), y Google lo rechazaba con `redirect_uri_mismatch` por traer `http://` en vez de `https://` — confirmado con un `curl` directo al contenedor (con el header puesto a mano SÍ funciona, ver auth-core-mc#068, que ya trae el fix del lado de Spring pero necesitaba este fix de Traefik para completarse en la topología real).

## Criterios de aceptación
- `traefik.yml`: `entryPoints.web.forwardedHeaders.trustedIPs` incluye `127.0.0.1/32` — el único origen que puede alcanzar ese entrypoint (ver `docker-compose.yml`: publicado solo en loopback).
- Verificado en vivo: un `curl` real contra `https://auth-dev.64bitstudio.com/oauth2/authorization/...` (sin headers manuales, a través de nginx→Traefik→contenedor) produce un `redirect_uri` con esquema `https://`.
- Verificado en vivo contra dev, como parte de la verificación de galgoth-studio#093: "Conectar" con una cuenta de Google real ya no falla con `redirect_uri_mismatch`.

## Hecho
Una línea de config (`trustedIPs: ["127.0.0.1/32"]`) en el entrypoint `web` de `traefik.yml`. `docker compose up -d` (el paso ya existente en `.github/workflows/ci.yml`) no recrea el contenedor Traefik solo por un cambio en el archivo de config bind-montado (el hash de servicio de Compose no cambia) — se forzó un recreate manual una sola vez vía SSH tras el merge (`docker compose -f deploy/vm-infra/traefik/docker-compose.yml up -d --force-recreate traefik`), documentado acá para quien busque por qué el propio job de CI no bastó.

CI verde (ver PR). Verificado en vivo: `curl` directo contra `auth-dev.64bitstudio.com` produce `redirect_uri=https://...`, y el flujo completo de "Conectar" con una cuenta de Google real en galgoth-studio#093 completa el consentimiento sin `redirect_uri_mismatch`.

No rompe compatibilidad — estrictamente aditivo, y `127.0.0.1/32` es exactamente (y únicamente) quien ya podía alcanzar este entrypoint, así que no amplía qué se confía, solo corrige que Traefik confíe en la fuente que la propia topología ya asume confiable.
