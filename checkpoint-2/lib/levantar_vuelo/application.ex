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
          {Registry, keys: :unique, name: LevantarVuelo.Registry},
          LevantarVuelo.AlertIndex,
          {DynamicSupervisor, strategy: :one_for_one, name: LevantarVuelo.DynamicSupervisor},
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
