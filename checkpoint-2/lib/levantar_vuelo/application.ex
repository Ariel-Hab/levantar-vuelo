defmodule LevantarVuelo.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      cluster_children() ++
        [
          # Registro distribuido: "vuelo X -> pid" visible desde cualquier nodo.
          # members: :auto hace que Horde sume y saque nodos solo, a medida que
          # libcluster los conecta o se caen.
          # sync_interval: cada cuánto se propaga el registro a los otros nodos
          # (por defecto 300 ms). Mientras no se propaga, otro nodo no encuentra
          # un vuelo recién creado; FlightServer reintenta un poco por eso.
          {Horde.Registry,
           name: LevantarVuelo.Registry,
           keys: :unique,
           members: :auto,
           delta_crdt_options: [sync_interval: 100]},
          # Alertas replicadas en todos los nodos con un CRDT (AP): cada nodo tiene
          # su copia y se sincronizan solas. Ver AlertIndex.
          LevantarVuelo.AlertIndex,
          # Avisos a usuarios (ver Notifier). PubSub entrega los mensajes entre
          # nodos solo; las tareas son para no frenar al FlightServer que avisa.
          {Phoenix.PubSub, name: LevantarVuelo.PubSub},
          {Task.Supervisor, name: LevantarVuelo.NotifierTasks},
          # Copias de vuelos de este y otros nodos. Va antes que los FlightServer,
          # que al arrancar le piden la última copia de su vuelo.
          LevantarVuelo.ReplicaStore,
          # Supervisor distribuido: elige en qué nodo vive cada FlightServer y, si el
          # nodo se cae, lo reinicia en otro. UniformQuorumDistribution además apaga
          # los procesos de un nodo que queda aislado de la mayoría (partición de red).
          {Horde.DynamicSupervisor,
           name: LevantarVuelo.DynamicSupervisor,
           strategy: :one_for_one,
           distribution_strategy: Horde.UniformQuorumDistribution,
           members: :auto},
          {Bandit, plug: LevantarVuelo.Router, port: System.get_env("PORT", "4000")}
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: LevantarVuelo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # libcluster conecta los nodos entre sí. No reemplaza a ningún otro supervisor:
  # es un hijo más. Va primero para que el cluster se forme mientras arrancan los demás.
  # Sin topologías configuradas (tests, desarrollo local) no se agrega nada.
  defp cluster_children do
    case Application.get_env(:levantar_vuelo, :cluster_topologies, []) do
      [] -> []
      topologies -> [{Cluster.Supervisor, [topologies, [name: LevantarVuelo.ClusterSupervisor]]}]
    end
  end
end
