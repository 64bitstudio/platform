# Definición: Vault como secrets manager general de la VM compartida

**✅ VoBo final de Marco confirmado (2026-09-01).** Documento cerrado
para definición — listo para desglosar en tickets reales
(`platform/003` a `007`). Cualquier cambio de alcance a partir de aquí
se gestiona como cambio de ticket, no editando este documento.

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

**Reformulado 2026-09-01 — hallazgo real, no solo higiene**: al
verificar el estado actual se confirmó (sin exponer valores,
`length()>0` sobre los `.env` reales) que `VAULT_ADDR`/`VAULT_ROOT_TOKEN`
están **vacíos hoy en DEV, QA y PROD** de `auth-core-mc` — el propio
código lo advierte: *"Vacío = TenantIdentityProviderService fallará
ruidosamente si algún tenant intenta configurar un secreto social"*
(pregunta abierta desde el ticket 049, nunca resuelta). Es decir: el
motor Transit de cifrado de secretos de tenant (ticket 017) **no está
conectado a ningún Vault real en ningún ambiente desplegado hoy** — no
es un riesgo teórico, es una funcionalidad rota en este momento. Marco
confirmó (2026-09-01) que este mismo Vault de infra debe resolver
también ese hueco — un solo Vault, no dos.

### Usuarios y roles involucrados
| Rol | Qué hace en este cambio |
|---|---|
| **Marco (operador único)** | Único humano con acceso de administrador a Vault; ejecuta la migración y el resize; guarda el respaldo manual de unseal keys en su gestor de contraseñas. |
| **Jenkins (pipeline)** | Consumidor automatizado — se autentica vía AppRole, lee solo los secretos de su política (least privilege), nunca el árbol completo. |
| **Backend de `auth-core-mc` (y futuros cores que lo necesiten)** | Consumidor automatizado nuevo, en tiempo de ejecución (no solo deploy): llama al motor Transit de Vault para cifrar/descifrar secretos de tenant. Su propia AppRole, distinta de la de Jenkins — el `SecretID` se inyecta como env var al deploy, mismo mecanismo que ya usa `DB_PASSWORD` hoy. |
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
- **Motor Transit de Vault, habilitado desde el día uno** (no es un
  KV genérico solamente) — resuelve el hueco real de hoy: conectar
  `VAULT_ADDR`/`VAULT_ROOT_TOKEN` (vacíos actualmente en DEV/QA/PROD)
  a este mismo Vault, con la clave `auth-core-mc-tenant-keys` ya
  esperada por el código. AppRole propia para el backend de
  `auth-core-mc` (distinta de la de Jenkins), inyectada como env var al
  deploy.
- **PAT de GitHub nuevo y acotado para Jenkins/CI**, generado y guardado
  en Vault en el mismo esfuerzo — reemplaza al PAT compartido actual
  (que tiene permisos de administrador y puede saltarse branch
  protection, hallazgo real del ticket 002). Scope mínimo necesario
  (checkout, webhook, push a ramas de despliegue), sin permisos de
  admin/owner.
- **Alerta por Telegram si Vault queda sellado/inalcanzable** (mismo
  canal/bot que ya usa el pipeline) — para enterarse antes de que un
  deploy falle, no después.
- Respaldo manual de las unseal keys (Shamir) en el gestor de
  contraseñas de Marco, como red de seguridad si el auto-unseal de OCI
  KMS llegara a fallar.
- Actualizar `docs/ARQUITECTURA.md` y la memoria de roadmap con el
  diseño final.

### No incluye
- Autenticación de GitHub Actions vía OIDC contra Vault (eliminar
  GitHub Actions Secrets por completo) — se deja como HU *stretch*,
  fuera del alcance obligatorio de la primera versión (ver HU-6).
- **Retirar o migrar el Vault que ya existe en la Mac de Marco**
  (`~/dev-infra`) — sigue existiendo, para uso puramente local
  (desarrollo/pruebas en su propia máquina). Lo que SÍ cambia: deja de
  ser (o de estar pensado para ser) lo que sirve Transit a los
  ambientes reales desplegados — eso pasa a ser exclusivamente el Vault
  de la VM, resolviendo el hueco de HU-7. Retirar el de la Mac por
  completo queda como decisión aparte, futura, no parte de este
  documento.
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

### HU-7 (sumada 2026-09-01): Login social funciona de verdad en todos los ambientes
Como tenant de `auth-core-mc`, quiero poder configurar mis credenciales
de login social (Google/Facebook) en cualquier ambiente, para que la
funcionalidad no falle silenciosamente por falta de un Vault real
conectado.

Criterios de aceptación:
- Dado el motor Transit habilitado en el Vault de la VM, cuando un
  tenant configura un `client_secret` social en DEV, QA o PROD,
  entonces se cifra/descifra correctamente — sin el error ruidoso que
  hoy produce `TenantIdentityProviderService` con `VAULT_ADDR` vacío.
- Dado el backend de `auth-core-mc`, cuando arranca en cualquier
  ambiente, entonces se autentica contra Vault con su propia AppRole
  (no la de Jenkins) — inyectada al deploy igual que `DB_PASSWORD` hoy.
- Dado que el `SecretID` de esta AppRole se filtrara, entonces el daño
  queda acotado a operaciones de Transit sobre las claves de
  `auth-core-mc` — no al resto de Vault.

### HU-8 (sumada 2026-09-01): Alerta si Vault queda inalcanzable
Como operador único, quiero enterarme por Telegram si Vault queda
sellado/inalcanzable, para no descubrirlo hasta que un deploy falle.

Criterios de aceptación:
- Dado que un healthcheck periódico (o el propio intento de un
  pipeline) detecta que Vault no responde o está sellado, entonces se
  envía una alerta real por Telegram (mismo bot/canal que ya usa el
  pipeline), con suficiente contexto para actuar sin tener que
  investigar desde cero.

### HU-9 (sumada 2026-09-01): PAT de GitHub acotado, guardado en Vault
Como operador, quiero que Jenkins/CI usen un PAT de GitHub con el
mínimo privilegio necesario, para que un error de proceso (como el
push directo del ticket 002) no pueda saltarse branch protection.

Criterios de aceptación:
- Dado un PAT nuevo, generado con scope mínimo (checkout, webhook, push
  a ramas de despliegue — sin permisos de administrador/owner del
  repo), cuando se guarda en Vault y se conecta a Jenkins, entonces
  reemplaza al PAT compartido actual.
- Dado un intento de push directo a una rama protegida usando ese PAT
  nuevo, entonces GitHub lo rechaza (a diferencia de hoy, que lo
  permite con un aviso de "bypass").

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

**Motor Transit habilitado desde la instalación inicial** (no un paso
posterior) — es lo que resuelve HU-7. Clave `auth-core-mc-tenant-keys`
(el nombre que el código ya espera vía `VAULT_TRANSIT_KEY_NAME`), con
una policy de Transit dedicada (`encrypt`/`decrypt` sobre esa clave
únicamente, no administración del motor) para la AppRole del backend.
El Vault de la Mac (`~/dev-infra`) sigue existiendo para desarrollo
local — no se retira, pero deja de ser (o de estar pensado para ser) lo
que sirve a los ambientes reales.

**PAT de GitHub nuevo y acotado (HU-9)**: se genera con el scope mínimo
real que Jenkins necesita (confirmar exactamente cuáles al implementar
— probablemente `contents:write`, `metadata:read`, `webhooks:write` a
nivel fine-grained, sin `administration`), se guarda en Vault, y
reemplaza al PAT compartido actual en el credential store de Jenkins.
No elimina la necesidad de que exista un PAT (alguien tiene que poder
hacer checkout/push), pero sí el radio de daño de un error como el del
ticket 002.

**Alerta de Vault sellado (HU-8)**: el mecanismo más simple y
consistente con lo ya construido es que el propio job `sync-vm-infra`
(que ya corre en cada push) verifique el estado de sello de Vault
(`vault status`) y dispare la misma notificación de Telegram que ya usa
para éxito/fallo del pipeline — sin sumar un proceso de monitoreo
nuevo y separado.

## Diagramas

```mermaid
flowchart TB
    subgraph VM["VM OCI Ampere A1 (4 OCPU/24GB, ya redimensionada)"]
        Vault["Vault OSS<br/>Raft single-node<br/>+ motor Transit"]
        KMS["OCI KMS<br/>(auto-unseal)"]
        Jenkins["Jenkins<br/>(1 solo, org-wide)"]
        Lib["Shared Library<br/>vars/corePipeline.groovy"]
        Nginx["nginx<br/>(Basic Auth de infra)"]
        Apps["Stacks dev/qa/prod<br/>de CUALQUIER core<br/>(auth-core-mc, mail-core-mc, futuros)"]
        AuthBackend["Backend auth-core-mc<br/>(en ejecución, no solo deploy)"]

        Vault -- "auto-unseal al arrancar" --> KMS
        Jenkins -- "invoca" --> Lib
        Lib -- "AppRole infra (RoleID + SecretID)" --> Vault
        Lib -- "inyecta DB_PASSWORD/PAT/tokens<br/>en tiempo de deploy" --> Apps
        Lib -- "renderiza .htpasswd<br/>vía certbotDomains" --> Nginx
        Lib -- "verifica sello, alerta si falla" --> Vault
        AuthBackend -- "AppRole propia<br/>encrypt/decrypt Transit" --> Vault
    end

    GHA["GitHub Actions<br/>(sync-vm-infra, repo platform)"] -- "GitHub Actions Secrets<br/>(sin cambio en v1, ver HU-6)" --> Jenkins
    Marco["Marco<br/>(único operador)"] -- "unseal keys de respaldo<br/>(gestor de contraseñas)" -.-> Vault
    TG["Telegram<br/>(mismo bot del pipeline)"]
    Lib -.->|"si Vault está sellado"| TG
```
Muestra que la integración vive en la Shared Library, no en el
`Jenkinsfile` de cada core — cualquier core que ya la use (todos, desde
el ticket 002) hereda Vault automáticamente. El backend de
`auth-core-mc` es un consumidor aparte, en tiempo de ejecución, con su
propia AppRole para Transit. GitHub Actions sigue sin cambio en v1
(ver HU-6), y Marco solo entra como respaldo manual del unseal.

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

**Todos resueltos con VoBo de Marco (2026-09-01)** — se conservan
documentados abajo como registro de la decisión y su razón, no como
pendientes.

- ~~¿El resize de OCI Ampere A1.Flex requiere reinicio o es en
  caliente?~~ **Resuelto en la práctica, no de forma concluyente**:
  Marco guardó el cambio de shape y reinició la VM en el mismo paso
  (para también validar la resiliencia a reinicio del ticket 002), así
  que no quedó aislado si el resize por sí solo hubiera necesitado
  reinicio o no — irrelevante ya para este documento, el resize está
  hecho de cualquier forma.
- ~~¿Se fusiona este Vault con el de la Mac más adelante?~~ **Resuelto
  parcialmente (2026-09-01)**: el Vault de la VM pasa a ser el que
  sirve Transit a los ambientes reales (HU-7) — el de la Mac sigue
  existiendo, pero solo para desarrollo local. Queda abierto si algún
  día se retira el de la Mac por completo; no bloquea nada de este
  documento.
- ~~Memoria/CPU real de Vault en reposo~~ **Confirmado por Marco
  (2026-09-01): basta con medirlo durante la implementación, sin un
  límite predefinido en este documento.** No es un riesgo real dado el
  margen que ya da el resize (4 OCPU/24GB) — se mide con evidencia real
  como parte del ticket `platform/003`, mismo criterio ya usado con
  Jenkins/SonarQube.
- ~~Vault mismo como punto único de falla~~ **Aceptado explícitamente
  por Marco (2026-09-01) como tradeoff válido para esta etapa**
  (coherente con "nada opera con clientes reales todavía"). Mitigado
  con la alerta de Telegram (HU-8) + llaves de respaldo manual (HU-2) —
  sin HA real (explícitamente fuera de alcance). Se revisará cuando de
  verdad haga falta, no antes.
- **El PAT nuevo y acotado (HU-9) sigue siendo, por diseño, la única
  credencial que arranca la cadena de confianza** — vive en el
  credential store de Jenkins (UI), no en Vault, por el mismo motivo
  que el `SecretID` inicial de la AppRole de Jenkins (HU-3): algo tiene
  que existir fuera de Vault para poder autenticarse contra él la
  primera vez. **Confirmado por Marco (2026-09-01) como aceptable tal
  cual** — inevitable en cualquier diseño de secrets manager, ya
  acotado a scope mínimo (HU-9), sin protección adicional pedida.

## Impacto estimado (tickets tentativos)
El resize (HU-5, antes "Ticket A") ya está hecho — fuera de esta lista.
Siguientes tickets, en `platform` (numeración real siguiente: 003+):

- Ticket `platform/003`: Instalación de Vault (Raft, auto-unseal OCI
  KMS, motor Transit habilitado desde el inicio) — sin migrar nada
  todavía, solo la infra base + medición de recursos (HU-1 parcial,
  HU-2, prerrequisito de HU-7).
- Ticket `platform/004`: AppRole de Jenkins integrada en
  `vars/corePipeline.groovy` + migración de secretos de infra, ambiente
  por ambiente, empezando por DEV de `auth-core-mc` (HU-1 completa,
  HU-3, HU-4) + alerta de Telegram si Vault se sella (HU-8).
- Ticket `platform/005`: AppRole propia del backend de `auth-core-mc`
  para Transit — conecta `VAULT_ADDR`/`VAULT_ROOT_TOKEN` en DEV/QA/PROD,
  arregla el login social roto hoy (HU-7).
- Ticket `platform/006`: PAT de GitHub nuevo y acotado, guardado en
  Vault, reemplaza al compartido actual (HU-9).
- Ticket `platform/007` (stretch, no obligatorio): OIDC de GitHub
  Actions (HU-6) — solo si se decide perseguir después de que los
  anteriores estén estables.

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

**Segunda ronda (2026-09-01, misma fecha, tras aclarar riesgos y
preguntas abiertas antes del VoBo):**
- Hallazgo real verificado: `VAULT_ADDR`/`VAULT_ROOT_TOKEN` vacíos hoy
  en DEV/QA/PROD — el login social de `auth-core-mc` está roto en este
  momento, no es un riesgo teórico. Motiva HU-7, sumada al alcance.
- El motor Transit se suma al alcance obligatorio desde el día uno —
  ya no es "fusionar Vaults" como pregunta abierta, es que el Vault de
  la VM pasa a servir Transit a los ambientes reales (el de la Mac
  sigue existiendo, solo para desarrollo local).
- Alerta de Telegram si Vault se sella, sumada al alcance (HU-8).
- PAT de GitHub nuevo y acotado, sumado al alcance de este mismo
  esfuerzo en vez de quedar como ticket futuro aparte (HU-9).

## Adenda (2026-09-01, durante ticket 004): AppRole `platform-admin` para el agente de DevOps

**Hueco real que este documento no cubría**: el diseño original define
cómo se autentican los *consumidores* de secretos (Jenkins vía HU-3, el
backend de `auth-core-mc` vía HU-7) contra Vault con AppRoles acotados
de vida corta — pero no dice cómo el propio agente/operador hace el
trabajo *administrativo* de Vault (crear esos AppRoles, sus policies,
escribir los secretos migrados) a lo largo de varios tickets sin
sostener el token root de forma permanente. Se descubrió en la práctica,
al cerrar el ticket 003: el token root generado por `vault operator
init` se guardó en el gestor de contraseñas de Marco y se borró de la
VM (correcto, por diseño) — dejando al agente sin ninguna credencial
administrativa para empezar el ticket 004.

**Decisión de Marco (2026-09-01)**: crear un AppRole permanente
`platform-admin`, acotado (no root, no gestión del seal/KMS, no
habilitar/deshabilitar auth methods o secrets engines nuevos) pero con
lo necesario para el trabajo administrativo recurrente: `secret/*`
(crear/leer/actualizar/borrar secretos KV), `auth/approle/*`
(crear/gestionar AppRoles de consumidores), `sys/policies/acl/*`
(crear/gestionar sus policies), y lectura de `sys/mounts`/`sys/auth`
(para chequeos de idempotencia). Se prefirió esto sobre la alternativa
(repetir el préstamo temporal del token root en cada ticket que
necesite cambios administrativos) por consistencia con el resto del
diseño: Jenkins y el backend de `auth-core-mc` ya tienen AppRoles
permanentes propios — un AppRole administrativo permanente, pero
acotado, sigue el mismo patrón en vez de ser una excepción.

Bootstrap real: `deploy/vm-infra/vault/bootstrap-admin-approle.sh`
(idempotente, incluye pruebas positivas y negativas reales — confirmó
en vivo que `platform-admin` puede leer/escribir en `secret/` pero
recibe `403` al intentar `vault operator seal` o montar un secrets
engine nuevo). Detalle completo, incluyendo el manejo del SecretID
(nunca expuesto en ningún chat), en `docs/ARQUITECTURA.md`.
