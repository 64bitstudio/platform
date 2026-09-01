# Ticket 002 (fix real, 2026-09-01): imagen mínima para ejecutar comandos
# en los namespaces del HOST desde dentro de un paso de pipeline de
# Jenkins -- Jenkins mismo corre containerizado (ver
# deploy/vm-infra/jenkins/docker-compose.yml, "agent any" = el propio
# controller), sin `sudo` instalado y, más de fondo, sin ACCESO al
# filesystem/systemd real del host aunque lo instalara.
#
# Hallazgo real (primer deploy real a DEV vía la Shared Library, punto 4
# del ticket 002): el paso "Vhost de nginx (dev)" corría `sudo cp ...`/
# `sudo systemctl reload nginx` -- funcionaba antes porque ese mismo
# paso vivía en ci.yml, ejecutado por el runner self-hosted DIRECTO
# sobre el host de la VM (no containerizado). Al moverlo a la Shared
# Library (que corre dentro del contenedor de Jenkins), ese supuesto se
# rompió: `sudo: not found` (ni siquiera instalado), y aunque lo
# estuviera, seguiría sin ver `/etc/nginx` del host ni su systemd
# (namespaces de proceso/montaje distintos).
#
# Por qué NO alcanza con instalar `sudo` en la imagen de Jenkins: te
# hace root DENTRO del contenedor de Jenkins, no te saca de él.
# Por qué NO alcanza con solo bind-montar /etc/nginx: resuelve escribir
# el archivo, pero "systemctl reload nginx" seguiría hablando con el
# systemd DEL CONTENEDOR (que ni corre) -- no seria un reload real.
#
# Solución: Jenkins YA monta docker.sock (acceso equivalente a root del
# host, riesgo ya aceptado y documentado en docker-compose.yml de
# Jenkins) -- se usa para lanzar ESTE contenedor con
# `--privileged --pid=host`, y `nsenter --target 1 ...` re-ejecuta el
# comando dado DENTRO de los namespaces de PID 1 del host -- el mismo
# proceso real que ve systemd, así que "systemctl reload nginx" desde
# aquí SÍ reinicia el nginx real de la VM, no uno de un contenedor.
# Patrón estándar para este tipo de "container breakout" intencional
# (mismo que usan imágenes conocidas como justincormack/nsenter1) --
# se construye localmente en vez de depender de un pull externo en cada
# deploy.
FROM alpine:3.20
RUN apk add --no-cache util-linux
ENTRYPOINT ["nsenter", "--target", "1", "--mount", "--uts", "--ipc", "--net", "--pid", "--"]
