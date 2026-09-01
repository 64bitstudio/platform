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
# alcanzado vía el socket montado) + el plugin de compose v2.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
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

USER jenkins

COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt
