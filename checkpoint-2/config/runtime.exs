import Config

# Cluster por DNS (Docker). Si CLUSTER_DNS_QUERY está definida, libcluster le
# pregunta al DNS de Docker por ese nombre de servicio (ej. "app") y se conecta
# a cada IP que devuelva. Docker responde con la IP de todas las réplicas.
#
# DNSPoll arma los nombres de nodo como "<node_basename>@<ip>", así que cada
# nodo tiene que arrancar con --name levantar@<su IP> (lo hace docker/entrypoint.sh).
if query = System.get_env("CLUSTER_DNS_QUERY") do
  config :levantar_vuelo, :cluster_topologies,
    dns: [
      strategy: Cluster.Strategy.DNSPoll,
      config: [
        polling_interval: 2_000,
        query: query,
        node_basename: System.get_env("CLUSTER_NODE_BASENAME", "levantar")
      ]
    ]
end
