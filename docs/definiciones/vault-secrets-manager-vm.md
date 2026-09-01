# Definición: Vault como secrets manager general de la VM compartida

## Resumen ejecutivo
Hoy los secretos de infra de la VM (OCI Ampere A1, compartida entre
`auth-core-mc` y, más adelante, `mail-core-mc`) viven repartidos en
archivos sueltos (`/home/ubuntu/secrets/*`, `/etc/nginx/secrets/`,
GitHub Actions Secrets), generados ad hoc, sin rotación ni auditoría.
Este cambio instala un **Vault nuevo y dedicado** en la propia VM como
fuente única de esos secretos, con **auto-unseal vía OCI KMS** (para
que sobreviva un reinicio sin intervención manual) y **AppRole** como
método de autenticación de Jenkins/CI — reemplazando los archivos
sueltos como fuente de verdad, sin cambiar cómo Jenkins/nginx los
*consumen* en el último tramo (siguen llegando como archivo/env var en
el momento del deploy).

Incluye también, como prerrequisito, el **resize de la VM** de 2
OCPU/12GB a 4 OCPU/24GB dentro del tier Always Free de OCI (Ampere A1
permite hasta 4 OCPU/24GB repartibles entre instancias) — Marco decidió
seguir por esta vía sabiendo el tradeoff de recursos de un proceso más
corriendo en la máquina, con intención de revisarlo más adelante.

## Objetivo de negocio
Eliminar el manejo manual/ad hoc de secretos de infra (generación
suelta por SSH, sin inventario ni rotación) que hoy genera riesgo real
de error humano y ningún rastro auditable — reemplazándolo por una
fuente única, versionada en su historial de acceso, con rotación
posible sin tocar archivos a mano.

### Usuarios y roles involucrados
| Rol | Qué hace en este cambio |
|---|---|
| **Marco (operador único)** | Único humano con acceso de administrador a Vault; ejecuta la migración y el resize; guarda el respaldo manual de unseal keys en su gestor de contraseñas. |
| **Jenkins (pipeline)** | Consumidor automatizado — se autentica vía AppRole, lee solo los secretos de su política (least privilege), nunca el árbol completo. |
| **GitHub Actions (`sync-vm-infra`)** | Consumidor automatizado — hoy usa GitHub Actions Secrets; queda como pregunta abierta si también migra a leer de Vault (ver más abajo) o se queda como está. |

No hay roles humanos nuevos — sigue siendo un equipo de una persona.

## Alcance

### Incluye
- Vault OSS nuevo, contenedor Docker en la VM, storage backend **Raft
  integrado** (modo single-node, sin depender de un backend externo,
  compatible con sumar nodos más adelante sin migrar de backend).
- **Auto-unseal vía OCI KMS** — Vault se desella solo al arrancar,
  usando una clave de OCI KMS (mismo proveedor cloud que ya aloja la
  VM, no se suma un tercero nuevo).
- Política de **least privilege** por consumidor (Jenkins solo lee lo
  que su pipeline necesita, nunca el árbol completo de secretos).
- **AppRole** como método de autenticación de Jenkins contra Vault
  (RoleID + SecretID, tokens de vida corta — no un token maestro
  estático).
- Migración de los secretos ya existentes: `DB_PASSWORD` de
  dev/qa/prod, PAT de GitHub, `SONAR_TOKEN`, tokens de Telegram, hash
  del Basic Auth de nginx — uno a la vez, empezando por DEV (el de
  menor riesgo), verificando cada paso antes de seguir.
- El **resize de la VM** a 4 OCPU/24GB (prerrequisito, antes de sumar
  Vault) — con ventana de mantenimiento planeada, dado que PROD vive en
  la misma máquina.
- Respaldo manual de las unseal keys (Shamir) en el gestor de
  contraseñas de Marco, como red de seguridad si el auto-unseal de OCI
  KMS llegara a fallar.
- Actualizar `docs/ARQUITECTURA.md` y la memoria de roadmap con el
  diseño final.

### No incluye
- Autenticación de GitHub Actions vía OIDC contra Vault (eliminar
  GitHub Actions Secrets por completo) — se deja como HU *stretch*,
  fuera del alcance obligatorio de la primera versión (ver HU-6).
- Fusionar este Vault con el que ya existe en la Mac de Marco (motor
  Transit para cifrado por sobres de `auth-core-mc`, ticket 017) — son
  instancias **separadas**, propósitos distintos. Queda como pregunta
  abierta si eso se revisa más adelante (ver "Riesgos y preguntas
  abiertas").
- Alta disponibilidad real (múltiples nodos de Vault) — sigue siendo
  single-node; el diseño con Raft lo deja preparado para eso, pero no
  se implementa ahora.
- Migrar el ticket gemelo `mail-core-mc` a este Vault — lo hereda
  cuando arranque su propio ticket 011, no es parte de este cambio.
- Vault gestionando su propia credencial de acceso humano (login de
  Jenkins vía UI, por ejemplo) — eso sigue siendo gestión local de cada
  herramienta, como ya se decidió para Jenkins en el ticket 049.

## Historias de Usuario

### HU-1: Fuente única de secretos de infra
Como operador de la VM, quiero que los secretos de despliegue vivan en
un solo lugar (Vault), para no tener que rastrear archivos sueltos por
distintas rutas de la máquina.

Criterios de aceptación:
- Dado un secreto que hoy vive en `/home/ubuntu/secrets/auth-core-mc/.env.*`,
  `/home/ubuntu/secrets/jenkins/.env` o `/etc/nginx/secrets/`, cuando
  termina la migración, entonces su valor real vive en Vault
  (`secret/auth-core-mc/<ambiente>`, `secret/jenkins`,
  `secret/nginx/basic-auth`) y el archivo original deja de ser la
  fuente de verdad (puede seguir existiendo como artefacto renderizado
  en el último tramo del deploy, nunca editado a mano).
- Dado que se necesita rotar un secreto, entonces se actualiza en Vault
  y el siguiente deploy lo toma solo — sin editar archivos por SSH a
  mano.

### HU-2: Vault sobrevive un reinicio sin intervención manual
Como operador único (sin backup humano), quiero que Vault se
re-desselle solo tras un reinicio de la VM, para no quedar bloqueado
esperando poder desellarlo a mano cada vez que la VM se reinicia
(incluyendo el propio resize de este ticket).

Criterios de aceptación:
- Dado un reinicio real de la VM (reboot completo, no solo `docker
  restart` del contenedor de Vault), cuando el sistema termina de
  arrancar, entonces Vault queda desellado automáticamente vía OCI KMS,
  sin que Marco ejecute ningún comando.
- Dado que el auto-unseal vía OCI KMS falla (OCI KMS inalcanzable, por
  ejemplo), entonces Marco puede desellar manualmente con las unseal
  keys de respaldo guardadas en su gestor de contraseñas — documentado
  paso a paso, no improvisado en el momento.

### HU-3: Jenkins se autentica con mínimo privilegio
Como pipeline de Jenkins, quiero autenticarme contra Vault con
credenciales de vida corta y acceso acotado a lo que mi pipeline
necesita, para no manejar un token maestro de larga duración con
acceso a todo.

Criterios de aceptación:
- Dado un build de Jenkins que necesita `DB_PASSWORD` de un ambiente,
  cuando el pipeline se autentica con su AppRole, entonces recibe un
  token de Vault que **solo** puede leer los paths de secretos que su
  política permite (no el árbol completo).
- Dado que el `SecretID` del AppRole se filtrara, entonces el daño
  queda acotado a lo que esa política permite leer — no a todo Vault.
- Dado que Jenkins necesita el `SecretID` inicial para arrancar,
  entonces ese único bootstrap secret vive en el credential store
  propio de Jenkins (UI, como ya se decidió para su seguridad en el
  ticket 049) — es la única credencial que sigue fuera de Vault por
  diseño (alguien tiene que arrancar la cadena de confianza).

### HU-4: Migración sin downtime evitable
Como Product Owner, quiero que los secretos ya existentes se migren sin
romper DEV/QA/PROD a mitad del cambio, para no repetir la fricción real
que tuvimos con el pivote a Jenkins.

Criterios de aceptación:
- Dado el orden de migración (DEV → QA → Jenkins → PROD, de menor a
  mayor riesgo), cuando se migra cada categoría, entonces se verifica
  que ese ambiente sigue funcionando (deploy real, healthcheck real)
  antes de migrar la siguiente.
- Dado que algo falla a mitad de la migración de un ambiente, entonces
  existe una vía de rollback al archivo `.env` original de ese ambiente
  (no se borra el archivo viejo hasta confirmar que Vault funciona de
  punta a punta para ese ambiente).

### HU-5: VM redimensionada antes de sumar Vault
Como Product Owner, quiero que la VM tenga más recursos disponibles
antes de sumarle un proceso más (Vault), para no agravar el problema de
CPU ajustado que ya identificamos con Jenkins/SonarQube.

Criterios de aceptación:
- Dado el resize de 2 OCPU/12GB a 4 OCPU/24GB dentro de Always Free,
  cuando se ejecuta, entonces se hace en una ventana de mantenimiento
  avisada (PROD vive en la misma VM), confirmando primero si el
  mecanismo de resize de OCI para esta shape requiere reinicio o es en
  caliente (a verificar en la consola real de OCI antes de ejecutar, no
  asumido en este documento).
- Dado el resize completado, entonces se mide el uso real de
  CPU/memoria de la VM (mismo criterio que se usó para medir antes de
  instalar Jenkins) y se deja registrado en `docs/ARQUITECTURA.md`.

### HU-6 (stretch, fuera del alcance obligatorio): GitHub Actions sin secretos estáticos
Como workflow de GitHub Actions, quiero autenticarme contra Vault vía
OIDC (federación con el issuer de GitHub) en vez de usar GitHub Actions
Secrets estáticos, para eliminar por completo la necesidad de rotar
secretos manuales en dos lugares (Vault y GitHub).

Criterios de aceptación:
- Dado un workflow de `sync-vm-infra`, cuando corre, entonces obtiene
  `SONAR_TOKEN`/`TELEGRAM_*` de Vault vía un token OIDC de corta vida
  emitido por GitHub, sin ningún secreto estático guardado en GitHub.
- **No implementar en la primera versión** — solo evaluar si vale la
  pena una vez que Vault ya esté estable con Jenkins.

## Diseño técnico

**Vault OSS, contenedor Docker, storage backend Raft (single-node).**
Se descarta backend `file` (sin capacidad de snapshot/backup nativo,
guía oficial de HashiCorp ya lo trata como legado) y `Consul` (sumar un
segundo servicio solo para el backend de otro servicio no se justifica
en una sola VM). Raft en modo single-node es la recomendación vigente
de HashiCorp incluso para instalaciones de un solo nodo, y deja el
camino abierto a sumar nodos después sin migrar de backend — relevante
porque Marco dijo explícitamente que planea mejorar esto más adelante.

**Auto-unseal vía OCI KMS**, no Shamir manual ni Transit-unseal desde
el Vault de la Mac. Se descarta Transit-unseal-desde-la-Mac
explícitamente: la Mac de Marco no está encendida 24/7 y el objetivo
declarado del roadmap es justo que la Mac quede dedicada a codificar,
no a ser una dependencia de disponibilidad de la infra de producción —
depender de ella para desellar Vault reintroduce exactamente el
acoplamiento que se quiso evitar. OCI KMS sí es aceptable porque es el
mismo proveedor cloud ya en uso para la VM (no se suma un tercero
nuevo), y resuelve el objetivo real (HU-2: sobrevivir un reinicio sin
intervención manual). Riesgo residual: si OCI KMS mismo tiene una
caída, Vault no se auto-desella — mitigado con el respaldo manual de
Shamir keys (ver HU-2, segundo criterio).

**AppRole para Jenkins**, no un token estático de larga duración. El
`RoleID` puede vivir en el propio `Jenkinsfile` (no es secreto por
diseño); el `SecretID` es el único bootstrap secret que sigue fuera de
Vault, guardado en el credential store de Jenkins (UI). Se evalúa
"response wrapping" de Vault para la entrega inicial del `SecretID` si
en la implementación real se detecta que vale la pena el esfuerzo
extra — no bloqueante para el diseño.

**nginx no habla con Vault directamente** (no es Vault-aware sin
plugins de terceros que no vale la pena sumar). El hash de Basic Auth
se sigue renderizando como archivo en `/etc/nginx/secrets/` durante el
job `sync-vm-infra`, pero su valor de origen pasa a leerse de Vault en
ese mismo paso, no generarse ahí mismo como hoy.

## Diagramas

```mermaid
flowchart TB
    subgraph VM["VM OCI Ampere A1 (4 OCPU/24GB tras el resize)"]
        Vault["Vault OSS<br/>Raft single-node"]
        KMS["OCI KMS<br/>(auto-unseal)"]
        Jenkins["Jenkins<br/>(orquestador CI/CD)"]
        Nginx["nginx<br/>(Basic Auth de infra)"]
        Apps["Stacks dev/qa/prod<br/>(auth-core-mc)"]

        Vault -- "auto-unseal al arrancar" --> KMS
        Jenkins -- "AppRole (RoleID + SecretID)" --> Vault
        Jenkins -- "inyecta DB_PASSWORD/PAT/tokens<br/>en tiempo de deploy" --> Apps
        Jenkins -- "renderiza .htpasswd<br/>en sync-vm-infra" --> Nginx
    end

    GHA["GitHub Actions<br/>(sync-vm-infra)"] -- "GitHub Actions Secrets<br/>(sin cambio en v1, ver HU-6)" --> Jenkins
    Marco["Marco<br/>(único operador)"] -- "unseal keys de respaldo<br/>(gestor de contraseñas)" -.-> Vault
```
Muestra los tres consumidores automatizados (Jenkins, nginx vía
Jenkins, y GitHub Actions sin cambio en v1) y el único humano en el
diseño (Marco, solo como respaldo manual del unseal).

```mermaid
sequenceDiagram
    participant J as Jenkinsfile
    participant V as Vault
    participant A as Stack DEV/QA/PROD

    J->>V: login AppRole (RoleID + SecretID)
    V-->>J: token de corta vida (política least-privilege)
    J->>V: GET secret/auth-core-mc/<ambiente>
    V-->>J: DB_PASSWORD (solo ese ambiente)
    J->>A: docker compose up -d --env-file (renderizado en el momento)
    Note over J,A: El token de Vault expira solo;<br/>no queda credencial de larga duración en el runner.
```
Muestra el flujo real de un deploy leyendo su secreto en el momento,
sin credenciales de larga duración quedando en el runner entre builds.

## Riesgos y preguntas abiertas

- **¿El resize de OCI Ampere A1.Flex requiere reinicio o es en
  caliente?** No confirmado en este documento — se verifica en la
  consola real de OCI antes de ejecutar HU-5, y se planea ventana de
  mantenimiento asumiendo que sí lo requiere (peor caso), hasta
  confirmar lo contrario.
- **¿Se fusiona este Vault con el de la Mac (Transit, ticket 017) más
  adelante, o quedan separados para siempre?** Este documento asume
  separados (propósitos distintos: uno es cifrado por sobres de datos
  de aplicación, el otro es secrets manager de infra) — Marco debe
  confirmar si eso es aceptable a largo plazo o si prefiere unificarlos
  en una revisión futura.
- **Memoria/CPU real de Vault en reposo**, no medida todavía — se mide
  igual que se hizo con Jenkins/SonarQube antes de comprometerse a
  dejarlo corriendo 24/7, como parte de la implementación (no bloquea
  el diseño, pero si el número sale mal, puede forzar reconsiderar el
  resize de HU-5).
- **Vault mismo como punto único de falla**: si Vault cae y el
  auto-unseal también falla, todo deploy queda bloqueado hasta
  resolverlo a mano. Mitigado parcialmente por HU-2 (respaldo manual),
  pero es un tradeoff real y consciente de este diseño, no un problema
  resuelto del todo — coherente con lo que Marco ya aceptó explícitamente
  (mejorar esto más adelante).
- **Orden real del resize vs. la instalación de Vault**: este documento
  asume que el resize (HU-5) va ANTES de instalar Vault, para no sumar
  el proceso nuevo sobre la máquina ya ajustada — confirmar que Marco
  está de acuerdo con ese orden (implica que el resize, con su posible
  downtime, se ejecuta primero, sin tener a Vault todavía como
  motivación inmediata).

## Impacto estimado (tickets tentativos)
- Ticket A: Resize de la VM a 4 OCPU/24GB (HU-5) — probablemente el
  primero, desbloquea a los demás.
- Ticket B: Instalación de Vault (Raft, auto-unseal OCI KMS) — sin
  migrar nada todavía, solo la infra base + medición de recursos
  (HU-1 parcial, HU-2).
- Ticket C: AppRole de Jenkins + migración de secretos, ambiente por
  ambiente (HU-1 completa, HU-3, HU-4).
- Ticket D (stretch, no obligatorio): OIDC de GitHub Actions (HU-6) —
  solo si se decide perseguir después de que C esté estable.

Se refinan a tickets reales (`nuevo-ticket`) después del VoBo de Marco
sobre este documento.
