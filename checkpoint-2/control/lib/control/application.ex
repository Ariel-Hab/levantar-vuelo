defmodule Control.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    port = String.to_integer(System.get_env("PORT", "4001"))
    children = [{Bandit, plug: Control.Router, port: port}]

    Supervisor.start_link(children, strategy: :one_for_one, name: Control.Supervisor)
  end
end
