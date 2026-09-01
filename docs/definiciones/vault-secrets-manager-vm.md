# Definición: Vault como secrets manager general de la VM compartida

**Reformulado 2026-09-01** — versión original del 2026-08-31, revisada
tras el ticket `platform/002` (endurecimiento de la infra base) y el
resize real de la VM. Se conserva el diseño central (Vault + auto-unseal
vía OCI KMS + AppRole), actualizado contra lo que hoy existe de verdad
— ver "Qué cambió desde la versión original" al final antes de pedir
VoBo de nuevo.

## Resumen ejecutivo
Hoy los secretos de infra de la VM (OCI Ampere A1, compartida entre
`auth-core-mc`, `mail-core-mc` — ya conectado a la infra común vía el
ticket 002 — y cualquier core futuro) viven repartidos en archivos
sueltos (`/home/ubuntu/secrets/*`, `/etc/nginx/secrets/`, GitHub
Actions Secrets, el credential store de Jenkins), generados ad hoc, sin
rotación ni auditoría — y con un hallazgo real reciente que refuerza el
problema: el PAT de GitHub compartido (git, `gh` CLI, Jenkins) tiene
permisos de administrador que le permiten saltarse branch protection,
más privilegio del necesario para su uso cotidiano (ver
`platform/done/002-...md`, incidente del push directo). Este cambio
instala un **Vault nuevo y dedicado** en la propia VM (repo `platform`,
igual que el resto de la infra compartida) como fuente única de esos
secretos, con **auto-unseal vía OCI KMS** y **AppRole** como método de
autenticación de Jenkins/CI — integrado directamente en la Shared
Library (`vars/corePipeline.groovy`, construida en el ticket 002), así
que **todo core que ya use esa librería queda cubierto automáticamente**,
sin trabajo adicional por proyecto — coherente con el principio de
"máxima automatización" que Marco confirmó para toda la infra.

**El resize de la VM que este documento pedía como prerrequisito ya
está hecho** (2026-09-01): 2 OCPU/12GB → 4 OCPU/24GB, dentro de Always
Free, aplicado y verificado con un reinicio real de la VM — los 13
contenedores existentes y el runner volvieron solos, sin intervención
manual (ver `platform/done/002-...md`, punto 2). Ya no es parte del
alcance de este documento, es contexto ya resuelto: Vault se instala
sobre una VM con el doble de recursos que cuando se escribió la primera
versión de este documento, lo que reduce bastante el riesgo de CPU/
memoria que antes era la preocupación principal de sumar un proceso
más.

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
- Vault OSS nuevo, contenedor Docker en la VM (`platform/deploy/
  vm-infra/vault/`, mismo patrón que Traefik/SonarQube/Jenkins/
  Portainer), storage backend **Raft integrado** (modo single-node, sin
  depender de un backend externo, compatible con sumar nodos más
  adelante sin migrar de backend).
- **Auto-unseal vía OCI KMS** — Vault se desella solo al arrancar,
  usando una clave de OCI KMS (mismo proveedor cloud que ya aloja la
  VM, no se suma un tercero nuevo).
- Política de **least privilege** por consumidor (Jenkins solo lee lo
  que su pipeline necesita, nunca el árbol completo de secretos).
- **AppRole** como método de autenticación de Jenkins contra Vault
  (RoleID + SecretID, tokens de vida corta — no un token maestro
  estático), **integrado en `vars/corePipeline.groovy`** (la Shared
  Library del ticket 002) como un step reusable — cualquier core que
  ya invoque la librería (`auth-core-mc`, `mail-core-mc`, futuros) lo
  hereda automáticamente, sin tocar su propio `Jenkinsfile` más allá de
  declarar qué paths de secretos necesita.
- Migración de los secretos ya existentes: `DB_PASSWORD` de cada
  ambiente de cada core, el PAT de GitHub y `SONAR_TOKEN`/tokens de
  Telegram de Jenkins (`/home/ubuntu/secrets/jenkins/.env`), y el hash
  del Basic Auth de nginx (`/etc/nginx/secrets/vm-admin-tools.htpasswd`)
  — uno a la vez, empezando por DEV de `auth-core-mc` (el de menor
  riesgo), verificando cada paso antes de seguir.
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
- Migrar los secretos específicos de `mail-core-mc` (ya conectado a la
  infra vía la Shared Library desde el ticket 002, pero su lógica de
  negocio real — y por lo tanto sus secretos reales — es su propio
  ticket 011, sin empezar) — lo hereda gratis en cuanto Vault esté
  listo para `auth-core-mc`, no hace falta trabajo extra por proyecto.
- Vault gestionando su propia credencial de acceso humano (login de
  Jenkins vía UI, por ejemplo) — eso sigue siendo gestión local de cada
  herramienta, como ya se decidió para Jenkins en el ticket 049.
- **Acotar los permisos del PAT de GitHub compartido** (hallazgo real
  del ticket 002: puede saltarse branch protection) — es un cambio
  relacionado pero independiente, ya anotado como candidato a ticket
  futuro aparte; este documento no lo resuelve, aunque Vault sí sería
  el lugar natural para guardar un PAT nuevo y acotado el día que se
  cree.

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

### HU-5: VM redimensionada antes de sumar Vault — ✅ YA CUMPLIDA (2026-09-01)
Como Product Owner, quiero que la VM tenga más recursos disponibles
antes de sumarle un proceso más (Vault), para no agravar el problema de
CPU ajustado que ya identificamos con Jenkins/SonarQube.

Resuelta fuera de este documento, como parte de la verificación del
ticket 002: resize a 4 OCPU/24GB aplicado por Marco vía la consola de
OCI ("Edit instance"), y verificado con un reinicio real de la VM — los
13 contenedores existentes y el runner volvieron solos. No quedó
registrado un número de "uso real de CPU/memoria con Vault corriendo"
porque Vault todavía no existe — eso se mide como parte de la
implementación real de este documento (ver "Riesgos y preguntas
abiertas"), no de esta HU, que ya cerró.

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
    subgraph VM["VM OCI Ampere A1 (4 OCPU/24GB, ya redimensionada)"]
        Vault["Vault OSS<br/>Raft single-node"]
        KMS["OCI KMS<br/>(auto-unseal)"]
        Jenkins["Jenkins<br/>(1 solo, org-wide)"]
        Lib["Shared Library<br/>vars/corePipeline.groovy"]
        Nginx["nginx<br/>(Basic Auth de infra)"]
        Apps["Stacks dev/qa/prod<br/>de CUALQUIER core<br/>(auth-core-mc, mail-core-mc, futuros)"]

        Vault -- "auto-unseal al arrancar" --> KMS
        Jenkins -- "invoca" --> Lib
        Lib -- "AppRole (RoleID + SecretID)" --> Vault
        Lib -- "inyecta DB_PASSWORD/PAT/tokens<br/>en tiempo de deploy" --> Apps
        Lib -- "renderiza .htpasswd<br/>vía certbotDomains" --> Nginx
    end

    GHA["GitHub Actions<br/>(sync-vm-infra, repo platform)"] -- "GitHub Actions Secrets<br/>(sin cambio en v1, ver HU-6)" --> Jenkins
    Marco["Marco<br/>(único operador)"] -- "unseal keys de respaldo<br/>(gestor de contraseñas)" -.-> Vault
```
Muestra que la integración vive en la Shared Library, no en el
`Jenkinsfile` de cada core — cualquier core que ya la use (todos, desde
el ticket 002) hereda Vault automáticamente. GitHub Actions sigue sin
cambio en v1 (ver HU-6), y Marco solo entra como respaldo manual del
unseal.

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

- ~~¿El resize de OCI Ampere A1.Flex requiere reinicio o es en
  caliente?~~ **Resuelto en la práctica, no de forma concluyente**:
  Marco guardó el cambio de shape y reinició la VM en el mismo paso
  (para también validar la resiliencia a reinicio del ticket 002), así
  que no quedó aislado si el resize por sí solo hubiera necesitado
  reinicio o no — irrelevante ya para este documento, el resize está
  hecho de cualquier forma.
- **¿Se fusiona este Vault con el de la Mac (Transit, ticket 017) más
  adelante, o quedan separados para siempre?** Sigue sin resolver —
  este documento sigue asumiendo separados (propósitos distintos: uno
  es cifrado por sobres de datos de aplicación, el otro es secrets
  manager de infra). Marco debe confirmarlo.
- **Memoria/CPU real de Vault en reposo**, no medida todavía — se mide
  como parte de la implementación. Con la VM ya en 4 OCPU/24GB (el
  doble que cuando se escribió la primera versión de este documento),
  el riesgo de que este número fuerce reconsiderar el diseño es bajo,
  pero se sigue midiendo con evidencia real, no se asume.
- **Vault mismo como punto único de falla**: si Vault cae y el
  auto-unseal también falla, todo deploy queda bloqueado hasta
  resolverlo a mano. Mitigado parcialmente por HU-2 (respaldo manual),
  pero es un tradeoff real y consciente de este diseño — coherente con
  lo que Marco ya aceptó explícitamente (mejorar esto más adelante).
  Reforzado por el principio de automatización total que confirmó
  después de este documento: vale la pena que la implementación real
  incluya una alerta (Telegram, mismo canal que ya usa el pipeline) si
  Vault queda sellado/inalcanzable, para no descubrirlo hasta que un
  deploy falle.
- **El PAT compartido de GitHub sigue siendo un secreto de alto
  privilegio guardado fuera de Vault** (bootstrap de Jenkins, credential
  store de la UI) — coherente con el diseño (alguien tiene que arrancar
  la cadena de confianza, ver HU-3), pero el hallazgo del ticket 002
  (ese mismo PAT puede saltarse branch protection) hace más urgente,
  no menos, acotarlo — ver el ticket futuro ya anotado en "No incluye".

## Impacto estimado (tickets tentativos)
El resize (HU-5, antes "Ticket A") ya está hecho — fuera de esta lista.
Siguientes tickets, en `platform` (numeración real siguiente: 003+):

- Ticket `platform/003`: Instalación de Vault (Raft, auto-unseal OCI
  KMS) — sin migrar nada todavía, solo la infra base + medición de
  recursos (HU-1 parcial, HU-2).
- Ticket `platform/004`: AppRole integrado en `vars/corePipeline.groovy`
  + migración de secretos, ambiente por ambiente, empezando por DEV de
  `auth-core-mc` (HU-1 completa, HU-3, HU-4).
- Ticket `platform/005` (stretch, no obligatorio): OIDC de GitHub
  Actions (HU-6) — solo si se decide perseguir después de que 004 esté
  estable.

Se refinan a tickets reales (`nuevo-ticket`) después del VoBo de Marco
sobre este documento.

## Qué cambió desde la versión original (2026-08-31 → 2026-09-01)
- El resize (antes prerrequisito pendiente) ya está hecho y verificado
  con un reinicio real — deja de ser parte del alcance de este
  documento.
- El diseño ahora se integra explícitamente con la Shared Library de
  Jenkins (`vars/corePipeline.groovy`, construida en el ticket 002) en
  vez de ser una integración genérica sin mecanismo concreto — esto es
  lo que hace que la migración beneficie a todo core automáticamente,
  no solo a `auth-core-mc`.
- Se suma el hallazgo real del PAT con permisos excesivos (ticket 002)
  como motivación adicional, y como pregunta abierta nueva sobre si
  Vault debería alojar un PAT nuevo y acotado a futuro.
- Los paths de secretos y nombres de archivo se actualizaron contra lo
  que hoy existe de verdad en `platform` (no lo que existía cuando se
  escribió la primera versión, antes de la migración a este repo).
