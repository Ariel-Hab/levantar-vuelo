import Config

# Sin topologías no se forma ningún cluster (tests y `mix run` en local).
# En Docker las define config/runtime.exs a partir de CLUSTER_DNS_QUERY.
config :levantar_vuelo, :cluster_topologies, []

# Réplica de vuelos (ver LevantarVuelo.Replicas): cada vuelo se copia en `factor`
# nodos, un cambio se confirma cuando lo guardaron `write_quorum` y recuperar un
# vuelo necesita `read_quorum` respuestas. `timeout`: ms que se espera a las réplicas.
config :levantar_vuelo, :replication, factor: 3, write_quorum: 2, read_quorum: 2, timeout: 1_000

# Los tests corren en un solo nodo: con quórum 2 no se podría confirmar nada.
if config_env() == :test do
  config :levantar_vuelo, :replication, factor: 1, write_quorum: 1, read_quorum: 1, timeout: 1_000
end
