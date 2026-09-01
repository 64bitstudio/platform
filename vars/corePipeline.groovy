// Jenkins Shared Library de `platform` (ticket 002, punto 3). Registrada
// globalmente vía JCasC (deploy/vm-infra/jenkins/casc/jenkins.yaml,
// `unclassified.globalLibraries`, nombre "platform") -- cualquier core
// (auth-core-mc, mail-core-mc, futuros) la invoca desde su propio
// `Jenkinsfile` así:
//
//   @Library('platform') _
//   corePipeline(
//       projectName: 'auth-core-mc',
//       healthPorts: [dev: 8081, qa: 8082, prod: 8080],
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
//   healthPorts    (Map, obligatorio si deploy != false)
//                                          [dev: <puerto>, qa: <puerto>, prod: <puerto>]
//                                          donde cada ambiente expone su healthcheck.
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

def call(Map config) {
    if (!config.projectName) {
        error("corePipeline: falta config.projectName")
    }
    def project = config.projectName
    def doDeploy = config.containsKey('deploy') ? config.deploy : true
    def hasBuild = config.buildAndTest != null
    def healthPath = config.healthPath ?: '/actuator/health'
    def healthyPattern = config.healthyPattern ?: '"status":"UP"'

    if (doDeploy && !config.healthPorts) {
        error("corePipeline: falta config.healthPorts (obligatorio salvo que config.deploy sea false)")
    }

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
            stage('Vhost de nginx (dev)') {
                when {
                    allOf {
                        branch 'dev'
                        expression { return doDeploy && config.vhostFile }
                    }
                }
                steps {
                    sh """
                        sudo cp ${config.vhostFile} /etc/nginx/sites-available/${project}.conf
                        sudo ln -sf /etc/nginx/sites-available/${project}.conf /etc/nginx/sites-enabled/${project}.conf
                        sudo nginx -t
                        sudo systemctl reload nginx
                    """
                }
            }

            stage('Deploy a DEV') {
                when { allOf { branch 'dev'; expression { return doDeploy } } }
                steps {
                    script {
                        deployAndVerify(project, 'dev', "${project}:${env.GIT_SHA}", env.GIT_SHA, config.healthPorts.dev, healthPath, healthyPattern)
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
                        deployAndVerify(project, 'qa', "${project}-dev:current", env.QA_SHA, config.healthPorts.qa, healthPath, healthyPattern)
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
                        deployAndVerify(project, 'prod', "${project}-qa:current", env.QA_SHA, config.healthPorts.prod, healthPath, healthyPattern)

                        // Registro en git: la rama `prod` avanza al mismo commit
                        // que se acaba de promover -- el historial de ramas sigue
                        // reflejando la realidad, aunque el despliegue en sí ya
                        // haya ocurrido vía este pipeline, no vía un merge.
                        withCredentials([usernamePassword(credentialsId: 'github-pat', usernameVariable: 'GIT_USER', passwordVariable: 'GIT_PAT')]) {
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
                        sh """
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

// Despliega la imagen `sourceImageRef` (referencia completa, ej.
// "auth-core-mc:abc123" o "auth-core-mc-dev:current") como
// "<project>-<envName>:<releaseTag>" + "<project>-<envName>:current",
// espera a que el healthcheck responda "arriba", y corre cleanup.sh --
// mismo procedimiento repetido antes en dev/qa/prod dentro de cada
// Jenkinsfile de core, ahora factorizado una sola vez.
def deployAndVerify(project, envName, sourceImageRef, releaseTag, port, healthPath, healthyPattern) {
    sh "docker tag ${sourceImageRef} ${project}-${envName}:${releaseTag}"
    sh "docker tag ${sourceImageRef} ${project}-${envName}:current"
    sh """
        IMAGE_TAG=current docker compose -f deploy/docker-compose.${envName}.yml --env-file /home/ubuntu/secrets/${project}/.env.${envName} up -d
    """
    sh """
        for i in \$(seq 1 30); do
            if curl -sf http://localhost:${port}${healthPath} | grep -q '${healthyPattern}'; then
                echo "${envName.toUpperCase()} healthy."; exit 0
            fi
            echo "Esperando a que ${envName.toUpperCase()} quede healthy... (\$i/30)"; sleep 5
        done
        echo "${envName.toUpperCase()} nunca quedó healthy." >&2; exit 1
    """
    sh "IMAGE_TAG=current docker compose -f deploy/docker-compose.${envName}.yml --env-file /home/ubuntu/secrets/${project}/.env.${envName} ps"
    sh "./deploy/cleanup.sh ${envName}"
}
