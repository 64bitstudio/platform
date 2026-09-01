# Arquitectura — platform

Documentación general de arquitectura/estrategia de 64bitstudio que no
pertenece a un solo core. La historia técnica detallada de cómo se
construyó cada pieza de infra (Jenkins, Traefik, SonarQube, Portainer)
antes de migrar aquí vive en `auth-core-mc/docs/ARQUITECTURA.md`,
tickets 049/050 — no se reescribe esa historia, este documento describe
el estado *actual* post-migración conforme avanza el ticket 001.

## Visión general
Ver memoria del equipo `saas-paas-cores-strategy`: 64bitstudio
construye "cores" reusables (auth-core, mail-core, futuros) sobre
infraestructura 100% gratuita (OCI Always Free), con doble modelo de
negocio — SaaS gestionado por Marco y PaaS/white-label para que un
tercero autoaloje la plataforma en su propia infra. Consecuencia de
diseño: los cores y esta infra compartida deben evitar supuestos
hardcodeados de la infra específica de Marco donde sea razonable.

## Estado actual
_Pendiente — se completa conforme avanza el ticket 001 (migración de
`deploy/vm-infra/*` desde `auth-core-mc`)._
