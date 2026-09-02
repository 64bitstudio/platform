// Jenkins Shared Library de `platform` (ticket 002, punto 3). Registrada
// globalmente vía JCasC (deploy/vm-infra/jenkins/casc/jenkins.yaml,
// `unclassified.globalLibraries`, nombre "platform") -- cualquier core
// (auth-core-mc, mail-core-mc, futuros) la invoca desde su propio
// `Jenkinsfile` así:
//
//   @Library('platform') _
//   corePipeline(
//       projectName: 'auth-core-mc',
//       vhostFile: 'deploy/vm-infra/nginx/auth-core-mc.conf',
//       buildAndTest: {
//           withEnv([...]) { dir('backend') { withSonarQubeEnv('sonarqube-vm') { sh './gradlew build sonar' } } }
//       }
//   )
//
// Reemplaza los ~200 líneas que antes vivían copiadas en cada
// Jenkinsfile de core (ver auth-core-mc/Jenkinsfile pre-ticket-002, en
// su historial de git) -- mismo comportamiento exacto, solo
// parametrizado. Ver docs/ARQUITECTURA.md ("Runbook: conectar un
// proyecto nuevo") para el contrato completo.
//
// Contrato de `config` (Map):
//   projectName    (String, obligatorio)  Nombre real del repo/imagen Docker
//                                          (ej. "auth-core-mc").
//   containerPort  (int, opcional)        Puerto en el que la app escucha DENTRO de su
//                                          propio contenedor (no el puerto publicado al
//                                          host -- ver "Hallazgo real" más abajo). Default
//                                          8080 (Spring Boot). Constante entre dev/qa/prod
//                                          a propósito: cada ambiente varía el puerto
//                                          PUBLICADO al host (ver docker-compose.*.yml de
//                                          cada core), pero el contenedor mismo siempre
//                                          escucha en el mismo puerto interno.
//   healthPath     (String, opcional)     Default '/actuator/health' (Spring Boot).
//                                          mail-core-mc (NestJS) usará '/health'.
//   healthyPattern (String, opcional)     Substring que debe aparecer en la respuesta
//                                          del healthcheck para considerarlo "arriba".
//                                          Default '"status":"UP"' (Spring Boot Actuator).
//   vhostFile      (String, opcional)     Ruta (dentro del propio checkout del core) al
//                                          vhost de nginx específico de este proyecto --
//                                          ej. "deploy/vm-infra/nginx/auth-core-mc.conf".
//                                          Si se omite, no se aplica ningún vhost (un core
//                                          que todavía no tiene dominio propio).
//   certbotDomains (List<String>, opcional) Dominios para los que correr `certbot --nginx`
//                                          justo después de aplicar vhostFile -- ej.
//                                          ['auth.64bitstudio.com', 'auth-qa.64bitstudio.com',
//                                          'auth-dev.64bitstudio.com']. Necesario SIEMPRE que
//                                          vhostFile tenga HTTPS real: el archivo que vive en
//                                          git es la versión sin el bloque 443/ssl (certbot lo
//                                          agrega en vivo, nunca se sincroniza a git) -- sin
//                                          esto, cada deploy pisaría ese bloque con la versión
//                                          solo-HTTP (ver "Incidente real" más abajo). Si se
//                                          omite (un core sin DNS/cert todavía), no corre nada.
//   buildAndTest   (Closure, opcional)    El paso real de compilar+testear+correr el
//                                          análisis de SonarQube -- distinto por stack
//                                          (gradle vs npm), así que la librería no lo
//                                          impone: cada Jenkinsfile pasa su propio closure,
//                                          responsable de llamar withSonarQubeEnv('sonarqube-vm')
//                                          { ... } y de posicionarse en su propio subdirectorio
//                                          (dir('backend')). Si se omite del todo (caso de un
//                                          core que apenas está conectando su infra, sin
//                                          pipeline de aplicación real todavía -- ver ticket
//                                          002 punto 11), la etapa queda como no-op explícito,
//                                          nunca oculto.
//   deploy         (boolean, opcional)    Default true. false desactiva TODAS las etapas de
//                                          imagen/vhost/deploy dev-qa-prod -- deja solo
//                                          build+test+Sonar+Quality Gate (si buildAndTest
//                                          está definido). Úsalo para el "Jenkinsfile mínimo"
//                                          de un core que todavía no tiene
//                                          Dockerfile/deploy/docker-compose.*.yml/cleanup.sh
//                                          reales (su propio ticket de pipeline los trae).
//
// Contrato de ramas (fijo para todo core, ver memoria de equipo
// saas-paas-cores-strategy): build+test+Sonar corre siempre; build de
// imagen + vhost + deploy a dev solo en `dev`; deploy a qa (promoviendo
// <project>-dev:current) solo en `qa`; gate manual (exclusivo de
// 'marco') + deploy a prod (promoviendo <project>-qa:current) también
// en `qa`, tras la aprobación.
//
// Hallazgo real (primer deploy real a DEV, 2026-09-01): Jenkins mismo
// corre containerizado (agent any = el propio controller, ver
// deploy/vm-infra/jenkins/docker-compose.yml) -- sin acceso directo al
// filesystem/systemd del host ni a los puertos publicados de OTROS
// contenedores vía "localhost". Dos consecuencias, ambas corregidas
// aquí:
//   1. El paso de vhost NO puede usar `sudo cp .../systemctl reload
//      nginx` directo (ni instalando sudo alcanzaría -- namespaces
//      distintos) -- usa la imagen "platform-host-exec" (nsenter hacia
//      el host, ver deploy/vm-infra/jenkins/host-exec/) vía docker.sock,
//      que Jenkins ya monta.
//   2. El healthcheck NO puede pegarle a "localhost:<puerto publicado>"
//      (eso es el loopback del contenedor de JENKINS, no del host) --
//      le pega directo al contenedor de la app por su nombre
//      (<project>-<env>-app-1), alcanzable porque ambos comparten la
//      red "edge" (verificado en vivo: docker exec jenkins curl
//      http://auth-core-mc-dev-app-1:8080/actuator/health -> 200 UP).

import groovy.transform.Field

// Ticket platform/004 (docs/definiciones/vault-secrets-manager-vm.md,
// HU-3): RoleID del AppRole "jenkins-infra" -- NO es secreto por diseño
// (ver el documento de definición, "AppRole para Jenkins"), por eso vive
// hardcodeado aquí en vez de en un archivo/credential. El SecretID (el
// único bootstrap secret que sigue fuera de Vault) vive en el
// credential store de Jenkins, ver casc/jenkins.yaml
// ("vault-jenkins-secret-id"). Generado en
// deploy/vm-infra/vault/bootstrap-jenkins-approle.sh -- si ese AppRole
// se recrea alguna vez (Vault reconstruido desde cero), este valor
// cambia y hay que actualizarlo aquí también.
//
// @Field (no una asignación de nivel de script simple) -- es el patrón
// correcto/documentado para una constante a nivel de script en un
// archivo vars/*.groovy de una Shared Library de Jenkins; una
// asignación bare aquí puede comportarse de forma inconsistente entre
// el binding del script y los métodos top-level que la usan bajo CPS.
@Field
String JENKINS_VAULT_APPROLE_ROLE_ID = '36a9755d-af3c-c050-2b78-5126cc829791'

def call(Map config) {
    if (!config.projectName) {
        error("corePipeline: falta config.projectName")
    }
    def project = config.projectName
    def doDeploy = config.containsKey('deploy') ? config.deploy : true
    def hasBuild = config.buildAndTest != null
    def containerPort = config.containerPort ?: 8080
    def healthPath = config.healthPath ?: '/actuator/health'
    def healthyPattern = config.healthyPattern ?: '"status":"UP"'
    // Ticket 004: por default, cualquier core con deploy real (doDeploy
    // true) obtiene su DB_PASSWORD de Vault automáticamente -- sin tocar
    // su propio Jenkinsfile, mismo principio que el resto de esta
    // librería. Escape hatch explícito (no silencioso) para el caso
    // excepcional de un core que todavía no migró su secreto a Vault.
    def skipVaultSecrets = config.skipVaultSecrets ?: false

    pipeline {
        agent any

        options {
            timestamps()
            disableConcurrentBuilds()
            buildDiscarder(logRotator(numToKeepStr: '30'))
        }

        stages {
            // El env var estándar del plugin de git (GIT_COMMIT) no queda
            // garantizado en un Multibranch Pipeline con checkout ligero --
            // se resuelve explícito, una sola vez, en vez de asumirlo.
            stage('Resolver SHA del commit') {
                steps {
                    script {
                        env.GIT_SHA = sh(script: 'git rev-parse HEAD', returnStdout: true).trim()
                    }
                }
            }

            stage('Build, test y análisis SonarQube') {
                when { expression { return hasBuild } }
                steps {
                    script { config.buildAndTest.call() }
                }
            }

            stage('(placeholder) build/test/Sonar sin configurar todavía') {
                when { expression { return !hasBuild } }
                steps {
                    echo "corePipeline: config.buildAndTest no está definido en el Jenkinsfile de ${project} -- placeholder explícito, sin build/test/Sonar real todavía (ver el ticket de pipeline propio de este core)."
                }
            }

            stage('Quality Gate de SonarQube') {
                // Requiere el webhook Sonar -> Jenkins ya configurado (ver
                // sync-vm-infra en platform/.github/workflows/ci.yml) --
                // sin él, esto se cuelga hasta el timeout.
                when { expression { return hasBuild } }
                steps {
                    timeout(time: 5, unit: 'MINUTES') {
                        waitForQualityGate abortPipeline: true
                    }
                }
            }

            stage('Build de la imagen (tag = SHA del commit)') {
                when { allOf { branch 'dev'; expression { return doDeploy } } }
                steps {
                    sh """
                        docker build \\
                            --label org.opencontainers.image.revision=${env.GIT_SHA} \\
                            -t ${project}:${env.GIT_SHA} \\
                            ./backend
                    """
                }
            }

            // Ya no huérfano (ticket 002, punto 4): antes dependía del
            // ci.yml propio de cada core (retirado). Ahora corre aquí, en
            // cada deploy a dev, con el vhost viviendo en el propio repo
            // del core (nunca en platform -- es específico de ese
            // proyecto).
            //
            // Corre vía la imagen "platform-host-exec" (nsenter hacia el
            // host, ver el "Hallazgo real" arriba y el Dockerfile de esa
            // imagen para el porqué completo) -- Jenkins lee el archivo
            // del vhost desde SU PROPIO checkout (dentro del contenedor)
            // y lo manda por stdin al contenedor host-exec, que lo
            // escribe en el /etc/nginx real del host y recarga el nginx
            // real (no uno de un contenedor).
            //
            // Incidente real (primer deploy real a DEV tras el fix del
            // punto anterior, 2026-09-01): el archivo tal como vive en
            // git es la versión SOLO-HTTP (sin bloque 443/ssl -- ver el
            // comentario del propio auth-core-mc.conf); el bloque 443/ssl
            // real lo agregó certbot DIRECTO en el archivo del host, a
            // mano, hace semanas, y nunca se sincronizó a git. El cp de
            // arriba lo pisó -- rompió HTTPS real de auth/auth-qa/
            // auth-dev.64bitstudio.com durante unos minutos (el
            // certificado en sí, en /etc/letsencrypt, nunca se tocó --
            // restaurado corriendo certbot de nuevo). ci.yml YA tenía
            // este mismo problema resuelto para jenkins.conf/
            // vm-admin-tools.conf: vuelve a correr certbot --nginx justo
            // después de cada cp, en cada push -- idempotente (si el
            // certificado sigue vigente, certbot solo reconfigura nginx,
            // no vuelve a pedirlo). Se replica el mismo patrón aquí.
            stage('Vhost de nginx (dev)') {
                when {
                    allOf {
                        branch 'dev'
                        expression { return doDeploy && config.vhostFile }
                    }
                }
                steps {
                    sh """
                        cat ${config.vhostFile} | docker run --rm -i --privileged --pid=host platform-host-exec sh -c '
                            cat > /etc/nginx/sites-available/${project}.conf &&
                            ln -sf /etc/nginx/sites-available/${project}.conf /etc/nginx/sites-enabled/${project}.conf &&
                            nginx -t &&
                            systemctl reload nginx
                        '
                    """
                    script {
                        if (config.certbotDomains) {
                            def domainArgs = config.certbotDomains.collect { "-d ${it}" }.join(' ')
                            sh """
                                docker run --rm --privileged --pid=host platform-host-exec sh -c '
                                    command -v certbot >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y certbot python3-certbot-nginx)
                                    certbot --nginx --non-interactive --agree-tos -m marco.cortes@64bitstudio.com ${domainArgs} --redirect
                                ' || echo "::warning::certbot falló para ${project} -- excepción conocida, no un silencio (revisar a mano si se repite; el certificado ya emitido no se pierde por esto)."
                            """
                        }
                    }
                }
            }

            stage('Deploy a DEV') {
                when { allOf { branch 'dev'; expression { return doDeploy } } }
                steps {
                    script {
                        if (!skipVaultSecrets) {
                            fetchAndPatchDbPasswordFromVault(project, 'dev')
                        }
                        deployAndVerify(project, 'dev', "${project}:${env.GIT_SHA}", env.GIT_SHA, containerPort, healthPath, healthyPattern)
                    }
                }
            }

            stage('Deploy a QA') {
                when { allOf { branch 'qa'; expression { return doDeploy } } }
                steps {
                    script {
                        env.QA_SHA = sh(
                            script: "docker inspect --format '{{ index .Config.Labels \"org.opencontainers.image.revision\" }}' ${project}-dev:current",
                            returnStdout: true
                        ).trim()
                        if (!env.QA_SHA) {
                            error("No se encontró ${project}-dev:current -- ¿corrió el deploy a DEV alguna vez?")
                        }
                        if (!skipVaultSecrets) {
                            fetchAndPatchDbPasswordFromVault(project, 'qa')
                        }
                        deployAndVerify(project, 'qa', "${project}-dev:current", env.QA_SHA, containerPort, healthPath, healthyPattern)
                    }
                }
            }

            // === GATE MANUAL DE PROD -- exclusivo de Marco, sin excepción ===
            stage('¿Promover a PROD?') {
                when { allOf { branch 'qa'; expression { return doDeploy } } }
                steps {
                    script {
                        try {
                            timeout(time: 7, unit: 'DAYS') {
                                input message: "¿Promover ${project}:${env.QA_SHA} (validado en QA) a PROD?",
                                      submitter: 'marco',
                                      ok: 'Promover a PROD'
                            }
                            env.PROD_APROBADO = 'true'
                        } catch (err) {
                            currentBuild.result = 'ABORTED'
                            error("Promoción a PROD no aprobada (rechazada o expiró el plazo): ${err}")
                        }
                    }
                }
            }

            stage('Deploy a PROD (sin rebuild)') {
                when {
                    allOf {
                        branch 'qa'
                        expression { return doDeploy }
                        environment name: 'PROD_APROBADO', value: 'true'
                    }
                }
                steps {
                    script {
                        if (!skipVaultSecrets) {
                            fetchAndPatchDbPasswordFromVault(project, 'prod')
                        }
                        deployAndVerify(project, 'prod', "${project}-qa:current", env.QA_SHA, containerPort, healthPath, healthyPattern)

                        // Registro en git: la rama `prod` avanza al mismo commit
                        // que se acaba de promover -- el historial de ramas sigue
                        // reflejando la realidad, aunque el despliegue en sí ya
                        // haya ocurrido vía este pipeline, no vía un merge.
                        //
                        // Ticket 006: credential cambiado a la GitHub App
                        // ("github-app", ver casc/jenkins.yaml) -- este push SIGUE
                        // funcionando sin necesitar ningún "bypass" ni permiso
                        // especial: el SHA que se empuja (env.QA_SHA) ya tiene un
                        // status check "continuous-integration/jenkins/branch" en
                        // SUCCESS, reportado durante el build de QA que promovió
                        // este mismo commit -- la protección de la rama exige que
                        // el SHA tenga ese check en verde, no que lo reciba en
                        // este momento.
                        //
                        // Verificado en vivo de verdad (no solo afirmado): rama de
                        // prueba con la MISMA protección real de `dev` copiada campo
                        // a campo, installation token real de esta misma GitHub App
                        // (flujo JWT completo, ver docs/ARQUITECTURA.md ticket 006),
                        // push directo (sin PR, sin check previo en verde) -- GitHub
                        // lo RECHAZÓ:
                        //   remote: error: GH006: Protected branch update failed...
                        //   remote: - Changes must be made through a pull request.
                        //   remote: - Required status check "continuous-integration/
                        //     jenkins/branch" is expected.
                        //   ! [remote rejected] ... (protected branch hook declined)
                        // A diferencia del PAT viejo (mismo escenario, mismo tipo de
                        // prueba, ver docs/definiciones/vault-secrets-manager-vm.md),
                        // que SÍ dejaba pasar el push con "Bypassed rule violations".
                        // La GitHub App no hereda el privilegio de admin/owner de
                        // ningún humano -- por eso el push normal de ESTE stage (SHA
                        // ya con el check en verde) sigue funcionando exactamente
                        // igual, sin necesitar ningún bypass.
                        withCredentials([usernamePassword(credentialsId: 'github-app', usernameVariable: 'GIT_USER', passwordVariable: 'GIT_PAT')]) {
                            sh """
                                git push https://\${GIT_USER}:\${GIT_PAT}@github.com/64bitstudio/${project}.git HEAD:refs/heads/prod
                            """
                        }
                    }
                }
            }
        }

        post {
            always {
                script {
                    if (env.TELEGRAM_BOT_TOKEN?.trim()) {
                        def emoji = currentBuild.currentResult == 'SUCCESS' ? '✅' : '🔴'
                        def msg = "*${emoji} [${project}] Jenkins ${env.BRANCH_NAME}*\n${currentBuild.currentResult} -- ${env.BUILD_URL}"
                        // Hallazgo real (ticket 011 de mail-core-mc, primer build real
                        // de su Jenkinsfile): igual que el token de Vault (ticket 004,
                        // ver fetchAndPatchDbPasswordFromVault) -- el `sh` de Jenkins
                        // corre con `set -x` por default, así que sin `set +x` explícito
                        // este comando quedaba impreso en el log de consola CON
                        // TELEGRAM_BOT_TOKEN ya resuelto en texto plano
                        // ("+ curl ... https://api.telegram.org/bot<token real>/..."),
                        // visible para cualquiera con acceso a los logs de Jenkins --
                        // en TODOS los builds de TODOS los cores (post{always} corre
                        // siempre, éxito o falla). No se rota el token aquí (fuera de
                        // alcance de este fix puntual) -- reportado a Marco para que
                        // decida si rotarlo.
                        sh """
                            set +x
                            curl -sS -X POST "https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendMessage" \\
                                -d chat_id=${env.TELEGRAM_CHAT_ID} \\
                                -d parse_mode=Markdown \\
                                --data-urlencode "text=${msg}" \\
                                > /dev/null || true
                        """
                    }
                }
            }
        }
    }
}

// Ticket platform/004 (HU-1 completa, HU-3, HU-4): obtiene DB_PASSWORD
// de Vault (secret/<project>/<envName>, motor KV v2) vía el AppRole
// "jenkins-infra" (login de vida corta -- token_ttl=15m, nunca un token
// maestro de larga duración) y lo escribe en el archivo REAL del host
// (/home/ubuntu/secrets/<project>/.env.<envName>), que es lo que
// deployAndVerify usa como --env-file. A partir de este ticket, Vault
// es la fuente de verdad -- el archivo queda como artefacto renderizado
// en cada deploy (HU-1), nunca editado a mano.
//
// El valor del secreto NUNCA se vuelve una variable de Groovy ni pasa
// por "echo" -- fluye completo dentro de un solo pipeline de shell
// (curl a Vault -> jq -> stdin de host-exec), igual que el patrón ya
// usado para el token root en la migración inicial (ver
// docs/ARQUITECTURA.md ticket 004). "jq" se agrega en el Dockerfile de
// Jenkins para esto -- no había necesidad de parsear JSON dentro de un
// step de pipeline hasta este ticket.
//
// El SecretID del AppRole (el único bootstrap secret fuera de Vault por
// diseño, ver el documento de definición) se inyecta vía el credential
// "vault-jenkins-secret-id" (ver casc/jenkins.yaml) -- masked
// automáticamente por credentials-binding en cualquier log de consola.
//
// Rollback real (HU-4): si Vault está sellado/inalcanzable o el
// secreto no existe todavía para este proyecto/ambiente, el step
// falla ruidosamente ANTES de tocar el archivo real -- el .env
// existente (con el valor anterior) queda intacto, nunca se pisa con
// un valor vacío/roto.
// Hallazgo real de seguridad (ticket 004, primer deploy real a DEV
// tras el merge, build #11 de auth-core-mc/dev): el `sh` de Jenkins
// corre con `set -x` (xtrace) por default -- cada comando se imprime
// en la consola CON las variables ya resueltas. Sin `set +x` explícito
// aquí, el token de Vault de vida corta (VAULT_TOKEN) quedaba impreso
// en texto plano en el log del build (`+ curl ... -H "X-Vault-Token:
// hvs...."`), visible para cualquiera con acceso a los logs de
// Jenkins. El token de ese build ya se revocó a mano
// (`vault token revoke -self`) en cuanto se detectó -- pero sin este
// fix se habría repetido en TODOS los deploys futuros de TODOS los
// cores que usen esta librería. `set +x` no afecta `set -e`/`-u`/
// `pipefail` (controlan cosas distintas) -- los `echo` explícitos de
// error siguen imprimiéndose igual, solo se apaga el eco automático de
// cada línea de comando.
// Ticket platform/005 (HU-7): generalizado para parchear no solo
// DB_PASSWORD sino cualquier campo presente en secret/<project>/<env>
// que el .env real ya declare (hoy: DB_PASSWORD siempre; VAULT_SECRET_ID
// -- el bootstrap secret de la AppRole "auth-core-mc-backend" para
// Transit -- desde que ese AppRole existe). Un solo login/fetch, un
// solo paso por host-exec, en vez de repetir el round-trip completo por
// campo. Un campo ausente en el JSON de Vault simplemente no se
// patchea (no es un error -- permite que proyectos sin VAULT_SECRET_ID
// todavía sigan funcionando con solo DB_PASSWORD).
//
// Cuidado con el nombre: el credential de Jenkins ("vault-jenkins-secret-id",
// el SecretID de la AppRole "jenkins-infra") y el campo "VAULT_SECRET_ID"
// dentro del JSON de Vault (el SecretID de la AppRole
// "auth-core-mc-backend", un consumidor DISTINTO) son dos secretos
// DIFERENTES que comparten un nombre parecido a propósito (mismo
// significado semántico, distinto dueño) -- por eso la variable de
// shell del credential de Jenkins se llama JENKINS_APPROLE_SECRET_ID
// aquí, para no confundirlas ni una con otra en el script.
def fetchAndPatchDbPasswordFromVault(project, envName) {
    withCredentials([string(credentialsId: 'vault-jenkins-secret-id', variable: 'JENKINS_APPROLE_SECRET_ID')]) {
        sh """
            set -euo pipefail
            set +x
            PAYLOAD=\$(jq -n --arg r "${JENKINS_VAULT_APPROLE_ROLE_ID}" --arg s "\$JENKINS_APPROLE_SECRET_ID" '{role_id:\$r, secret_id:\$s}')
            VAULT_TOKEN=\$(curl -sf -X POST http://vault:8200/v1/auth/approle/login -d "\$PAYLOAD" | jq -r '.auth.client_token // empty')
            if [ -z "\$VAULT_TOKEN" ]; then
                echo "No se pudo autenticar contra Vault (AppRole jenkins-infra) -- ¿está sellado/inalcanzable? No se toca el .env existente." >&2
                exit 1
            fi
            SECRET_JSON=\$(curl -sf -H "X-Vault-Token: \$VAULT_TOKEN" http://vault:8200/v1/secret/data/${project}/${envName})
            # Validar DB_PASSWORD ANTES de tocar el archivo -- garantiza el
            # rollback real de HU-4: si falta, no se escribe NADA (ni
            # siquiera los demás campos), el .env existente queda intacto.
            HAS_DB_PASSWORD=\$(echo "\$SECRET_JSON" | jq -r '.data.data.DB_PASSWORD // empty')
            if [ -z "\$HAS_DB_PASSWORD" ]; then
                echo "DB_PASSWORD vacío/no encontrado en Vault para ${project}/${envName} -- abortando sin tocar el archivo." >&2
                exit 1
            fi
            echo "\$SECRET_JSON" \\
                | jq -r '.data.data | to_entries | map(select(.key == "DB_PASSWORD" or .key == "VAULT_SECRET_ID")) | map("\\(.key)=\\(.value)") | .[]' \\
                | docker run --rm -i --privileged --pid=host platform-host-exec sh -c '
                    FILE=/home/ubuntu/secrets/${project}/.env.${envName}
                    if [ ! -f "\$FILE" ]; then
                        echo "\$FILE no existe -- no se puede parchear un archivo que no existe (ver rollback HU-4)." >&2
                        exit 1
                    fi
                    while IFS= read -r LINE; do
                        KEY=\$(echo "\$LINE" | cut -d= -f1)
                        VAL=\$(echo "\$LINE" | cut -d= -f2-)
                        [ -z "\$VAL" ] && continue
                        if grep -q "^\${KEY}=" "\$FILE"; then
                            sed -i "s|^\${KEY}=.*|\${KEY}=\${VAL}|" "\$FILE"
                        else
                            printf "%s=%s\\n" "\$KEY" "\$VAL" >> "\$FILE"
                        fi
                    done'
        """
    }
}

// Despliega la imagen `sourceImageRef` (referencia completa, ej.
// "auth-core-mc:abc123" o "auth-core-mc-dev:current") como
// "<project>-<envName>:<releaseTag>" + "<project>-<envName>:current",
// espera a que el healthcheck responda "arriba", y corre cleanup.sh --
// mismo procedimiento repetido antes en dev/qa/prod dentro de cada
// Jenkinsfile de core, ahora factorizado una sola vez.
//
// El healthcheck le pega directo al contenedor de la app por su NOMBRE
// (no "localhost:<puerto>" -- ver "Hallazgo real" en la cabecera de este
// archivo). El nombre lo fija Docker Compose de forma determinística
// como "<project.name del compose>-<service>-<replica>"; cada
// docker-compose.<env>.yml de un core declara "name: <project>-<env>" y
// el servicio se llama "app" con una sola réplica -- de ahí
// "<project>-<env>-app-1".
def deployAndVerify(project, envName, sourceImageRef, releaseTag, containerPort, healthPath, healthyPattern) {
    sh "docker tag ${sourceImageRef} ${project}-${envName}:${releaseTag}"
    sh "docker tag ${sourceImageRef} ${project}-${envName}:current"
    sh """
        IMAGE_TAG=current docker compose -f deploy/docker-compose.${envName}.yml --env-file /home/ubuntu/secrets/${project}/.env.${envName} up -d
    """
    def containerName = "${project}-${envName}-app-1"
    sh """
        for i in \$(seq 1 30); do
            if curl -sf http://${containerName}:${containerPort}${healthPath} | grep -q '${healthyPattern}'; then
                echo "${envName.toUpperCase()} healthy."; exit 0
            fi
            echo "Esperando a que ${envName.toUpperCase()} quede healthy... (\$i/30)"; sleep 5
        done
        echo "${envName.toUpperCase()} nunca quedó healthy." >&2; exit 1
    """
    sh "IMAGE_TAG=current docker compose -f deploy/docker-compose.${envName}.yml --env-file /home/ubuntu/secrets/${project}/.env.${envName} ps"
    sh "./deploy/cleanup.sh ${envName}"
}
