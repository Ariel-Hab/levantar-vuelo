import Config

# Sin topologías no se forma ningún cluster (tests y `mix run` en local).
# En Docker las define config/runtime.exs a partir de CLUSTER_DNS_QUERY.
config :levantar_vuelo, :cluster_topologies, []
