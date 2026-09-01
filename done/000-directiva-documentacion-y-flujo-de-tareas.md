# 000 — Directiva: documentación y flujo de tareas

## Objetivo
Dejar constancia, como en todo proyecto del equipo, de que este repo
sigue la convención `/pending /in-process /done /docs` (+
`docs/definiciones/` para cambios grandes) — sin carpeta `/postman`
porque este repo no expone endpoints propios (es infra-como-código +
documentación general).

## Reglas específicas de este repo (2026-08-31, decisión de Marco)
- **Ningún cambio de documentación (`docs/**`, tickets en
  `pending/in-process/done`) dispara flujo de CI/CD** — ni en este
  repo ni en ningún otro del equipo. Solo cambios reales de
  infra-como-código (`deploy/`, workflows, Dockerfiles, etc.) pasan
  por rama → PR → CI → merge.
- Este repo es la ubicación de la **documentación general** de
  arquitectura/estrategia de 64bitstudio (no específica de un core) —
  ver `docs/ARQUITECTURA.md` y la memoria del equipo
  `saas-paas-cores-strategy`.
- Cada core (`auth-core-mc`, `mail-core-mc`, futuros) sigue manteniendo
  su propia documentación específica en su propio repo — este repo no
  la reemplaza.

## Hecho
Bootstrap inicial del repo (2026-08-31): estructura de carpetas +
esqueleto de `/docs` + este ticket. Sin SonarQube (no hay código de
aplicación que analizar aquí, solo YAML/scripts/infra-as-code y docs) —
decisión explícita, no omisión silenciosa.
