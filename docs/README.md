# platform

Infraestructura compartida de 64bitstudio: Jenkins, Traefik, SonarQube,
Portainer, Vault, nginx — todo lo que corre en la VM compartida (OCI
Ampere A1) y no es específico de ningún "core" (`auth-core-mc`,
`mail-core-mc`, futuros). También aloja la documentación general de
arquitectura/estrategia que no pertenece a un solo proyecto.

Ver memoria del equipo `saas-paas-cores-strategy` para el porqué de
este repo, y `vm-deploy-infra-roadmap` para el estado técnico de la VM.

## Qué NO va aquí
Cada core (`auth-core-mc`, `mail-core-mc`, ...) mantiene su propio
`Jenkinsfile`, `docker-compose.{dev,qa,prod}.yml` y documentación
específica de su dominio — este repo no los reemplaza, solo aloja la
infra compartida de la que todos son consumidores.

## Setup
_Se completa conforme se migra la infra real desde `auth-core-mc`
(ticket 001) — todavía no hay nada corriendo desde este repo._
