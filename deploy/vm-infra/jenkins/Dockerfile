# Ticket 049 (pivote GH Actions -> Jenkins): imagen de Jenkins con el
# cliente Docker instalado. La imagen oficial jenkins/jenkins:lts NO trae
# el CLI de docker -- lo necesita para construir/etiquetar/desplegar
# contra el MISMO daemon Docker de la VM (no un daemon anidado, ver la
# nota de docker.sock en docker-compose.yml de este mismo directorio),
# reusando exactamente los mismos Dockerfile/docker-compose.*.yml/
# cleanup.sh que ya existen — sin eso, el Jenkinsfile no podría correr
# "docker build"/"docker compose up" desde dentro del contenedor de
# Jenkins.
FROM jenkins/jenkins:lts-jdk21

USER root

# docker-ce-cli (el CLI, no el daemon -- el daemon real es el de la VM,
# alcanzado vía el socket montado) + el plugin de compose v2 + jq
# (ticket 004: vars/corePipeline.groovy usa jq para parsear las
# respuestas JSON de la API de Vault dentro de un step "sh" -- más
# simple que sumar un plugin de Jenkins solo para parsear JSON).
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gnupg jq \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# El usuario "jenkins" de la imagen necesita pertenecer al mismo grupo
# (GID) que es dueño de /var/run/docker.sock en la VM para poder usarlo
# sin sudo -- se resuelve en runtime vía docker-compose.yml
# (group_add: ["${DOCKER_GID}"], no hardcodeado aquí porque el GID real
# de "docker" puede variar entre hosts).

# Hallazgo real (primer build real de dev vía Jenkins): "./gradlew build
# sonar" fallo -- "Cannot find a Java installation ... matching:
# {languageVersion=25...}. Toolchain download repositories have not been
# configured." La imagen base (jenkins/jenkins:lts-jdk21) solo trae JDK 21
# para correr JENKINS MISMO -- el backend requiere el toolchain Java 25
# (mismo que ci.yml provisionaba vía actions/setup-java). Se instala
# Temurin 25 aparte (Adoptium, mismo distribuidor que usaba
# actions/setup-java) SIN tocar el JDK 21 que Jenkins usa para si mismo --
# el Jenkinsfile activa este JAVA_HOME solo para el stage de build/Sonar
# (ver withEnv en Jenkinsfile), nunca a nivel de contenedor completo.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg \
    && chmod a+r /etc/apt/keyrings/adoptium.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
       > /etc/apt/sources.list.d/adoptium.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends temurin-25-jdk \
    && rm -rf /var/lib/apt/lists/*

# Ticket 011 de mail-core-mc: toolchain Node.js + sonar-scanner CLI --
# mismo motivo/patrón que Temurin 25 arriba (auth-core-mc), pero para un
# core Node/NestJS en vez de Gradle. Gradle trae su propio plugin de
# Sonar (self-contained, "./gradlew sonar") -- npm no tiene equivalente,
# así que hace falta el CLI real de SonarScanner, que mail-core-mc/
# Jenkinsfile activa solo dentro de su propio buildAndTest (withEnv,
# PATH+SONAR=/opt/sonar-scanner/bin), sin tocar el resto del contenedor.
#
# NodeSource (mismo criterio que Adoptium para Temurin arriba: repo del
# propio distribuidor, no un tarball genérico) -- Node 24 LTS, misma
# versión que actions/setup-node usaba en el ci.yml retirado de
# mail-core-mc.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
    && curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# sonar-scanner CLI oficial (bundle con JRE propio, sin depender del
# JDK 21/25 ya instalados arriba) -- descarga directa de SonarSource,
# versión pineada (mismo criterio que el resto de este Dockerfile: nunca
# ":latest" sin fijar). Detecta arquitectura -- la VM real es ARM64
# (OCI Ampere), pero el Dockerfile debe seguir funcionando igual en una
# Mac amd64/arm64 si algún día se necesita reconstruir la imagen ahí.
RUN apt-get update \
    && apt-get install -y --no-install-recommends unzip \
    && rm -rf /var/lib/apt/lists/* \
    && ARCH=$(dpkg --print-architecture) \
    && case "$ARCH" in \
         amd64) SONAR_ARCH=linux-x64 ;; \
         arm64) SONAR_ARCH=linux-aarch64 ;; \
         *) echo "sonar-scanner: arquitectura no soportada: $ARCH" >&2; exit 1 ;; \
       esac \
    && SONAR_SCANNER_VERSION=6.2.1.4610 \
    && curl -fsSL -o /tmp/sonar-scanner.zip \
         "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}-${SONAR_ARCH}.zip" \
    && unzip -q /tmp/sonar-scanner.zip -d /opt \
    && mv "/opt/sonar-scanner-${SONAR_SCANNER_VERSION}-${SONAR_ARCH}" /opt/sonar-scanner \
    && rm /tmp/sonar-scanner.zip

USER jenkins

COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

# Ticket 006: hallazgo real (primer intento de pasar la llave privada de
# la GitHub App como env var de Docker Compose) -- Compose interpola
# "${VAR}" como texto plano ANTES de parsear el YAML del compose file;
# un valor multilínea (la llave PEM real) rompe la estructura YAML
# resultante y el error observado en vivo fue "Process completed with
# exit code 127" con fragmentos de la llave impresos como si fueran
# comandos. Solución estándar para este problema conocido (env vars
# multilínea a través de Docker Compose): el valor viaja codificado en
# base64 (una sola línea, seguro para la interpolación de Compose,
# ver docker-compose.yml -- GITHUB_APP_PRIVATE_KEY_B64) y se decodifica
# AQUÍ, dentro del propio contenedor, antes de que Jenkins arranque --
# nunca pasa por la capa de interpolación de Compose en su forma real
# multilínea.
USER root
COPY docker-entrypoint-wrapper.sh /usr/local/bin/docker-entrypoint-wrapper.sh
RUN chmod +x /usr/local/bin/docker-entrypoint-wrapper.sh
USER jenkins
# Mismo ENTRYPOINT/CMD que la imagen base (tini -- jenkins.sh), con el
# wrapper de arriba insertado antes de tini -- comportamiento idéntico
# salvo por el decode de la llave, "exec" preserva a tini como PID 1
# real (reaping de zombies intacto).
ENTRYPOINT ["/usr/local/bin/docker-entrypoint-wrapper.sh"]
CMD ["/usr/local/bin/jenkins.sh"]

