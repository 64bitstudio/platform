# Ticket platform/003 (definición: docs/definiciones/vault-secrets-manager-vm.md,
# VoBo Marco 2026-09-01) -- config real de Vault Community Edition para la
# VM compartida. Mismos IDs de recursos OCI que documenta
# docs/ARQUITECTURA.md (no son secreto -- un OCID/endpoint no autoriza nada
# por sí mismo sin la identidad de la instancia, mismo criterio ya usado
# para el RoleID de AppRole en el documento de definición).

ui = true

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
  # Sin TLS a propósito: Vault solo se alcanza (a) desde 127.0.0.1 de la
  # propia VM (SSH + túnel, uso administrativo de Marco) y (b) desde otros
  # contenedores de la red interna "vm-infra" (Jenkins, y más adelante el
  # backend de auth-core-mc, ticket 005) -- nunca expuesto a Traefik/
  # internet (sin labels de Traefik en el docker-compose.yml de este
  # servicio). Mismo modelo de confianza ya aceptado para Jenkins <->
  # SonarQube (también HTTP plano sobre "vm-infra", ver
  # deploy/vm-infra/sonarqube/docker-compose.yml) -- no es una categoría de
  # riesgo nueva para esta VM.
}

storage "raft" {
  path    = "/vault/file"
  node_id = "vault-vm-1"
  # Single-node a propósito (ver docs/definiciones/vault-secrets-manager-vm.md,
  # "Diseño técnico") -- Raft deja el camino abierto a sumar nodos después
  # sin migrar de backend, pero eso no es parte de este ticket.
  #
  # Hallazgo real (ticket 003, verificado en vivo): "/vault/data" (la ruta
  # que usan la mayoría de los tutoriales de Raft) NO funciona con la
  # imagen oficial de Docker -- su docker-entrypoint.sh solo hace
  # `chown vault:vault` de /vault/config, /vault/logs y /vault/file si
  # detecta que están bind-mounted (comparando el UID dueño contra el del
  # usuario "vault" dentro del contenedor); /vault/data no es una ruta que
  # el entrypoint conozca, así que un volumen nombrado ahí queda con dueño
  # root y Vault (que corre como usuario no-root) falla con "permission
  # denied: open /vault/data/vault.db" en el primer arranque. Usar
  # "/vault/file" en vez de "/vault/data" resuelve esto sin workarounds
  # (initContainer, chmod manual, correr como root) -- es la ruta que la
  # propia imagen ya sabe preparar.
}

# Auto-unseal vía OCI KMS (HU-2) -- instance principal (auth_type_api_key
# = false), NO llaves de API estáticas: la identidad la valida OCI vía el
# IMDS de la propia VM + el Dynamic Group/Policy dedicados (ver
# docs/ARQUITECTURA.md, "Vault -- OCI KMS auto-unseal" para los OCID
# reales del Dynamic Group y la Policy). Confirmado en vivo (ticket 003)
# que un contenedor con networking por default SÍ alcanza
# 169.254.169.254 desde esta VM -- sin necesitar --network=host.
seal "ocikms" {
  key_id              = "ocid1.key.oc1.mx-queretaro-1.ibvjm2v7aaana.abyxeljr6u3fcjpcn6aj5wr3o2mtyf2yggk63r6yfrgrdk5wke26gzn6f4ha"
  crypto_endpoint     = "https://ibvjm2v7aaana-crypto.kms.mx-queretaro-1.oci.oraclecloud.com"
  management_endpoint = "https://ibvjm2v7aaana-management.kms.mx-queretaro-1.oci.oraclecloud.com"
  auth_type_api_key   = "false"
}

# Vault 2.0+ (Community Edition): la capability IPC_LOCK ya no está
# disponible dentro de la imagen oficial de contenedor (removida por
# HashiCorp a propósito, ver release notes 2.0 -- "operators should set
# disable_mlock = true"). No es una relajación de seguridad real en esta
# VM: `free -h` confirma Swap: 0B (sin swap habilitado), así que no hay
# a dónde podría "filtrarse" un secreto por falta de mlock().
disable_mlock = true

# Nombre de servicio Docker ("vault"), no localhost ni IP -- mismo patrón
# que "sonarqube:9000"/"jenkins:8080" en el resto de esta infra (los
# contenedores se resuelven por nombre en la red "vm-infra").
api_addr     = "http://vault:8200"
cluster_addr = "http://vault:8200"

log_level = "info"
