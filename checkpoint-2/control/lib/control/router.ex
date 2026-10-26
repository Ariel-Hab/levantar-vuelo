defmodule Control.Router do
  @moduledoc """
  API para levantar y bajar nodos del cluster (los contenedores de `app`).

  Es un plano de control: no es parte del sistema de vuelos, lo maneja desde
  afuera. Escucha en localhost:4001 (ver docker-compose.yml).
  """
  use Plug.Router

  alias Control.Docker

  @actions %{"kill" => :kill, "stop" => :stop, "start" => :start}

  plug :match
  plug :dispatch

  # GET /nodes — todos los nodos, corriendo o parados
  get "/nodes" do
    json(conn, 200, Docker.list_nodes())
  end

  # POST /nodes/start — levanta todos los nodos que estén parados
  post "/nodes/start" do
    started =
      for %{state: state, container: container} <- Docker.list_nodes(), state != "running" do
        Docker.node_action(container, :start)
        container
      end

    json(conn, 200, %{started: started})
  end

  # POST /nodes/:container/kill | stop | start — una acción sobre un nodo
  post "/nodes/:container/:action" when is_map_key(@actions, action) do
    case Docker.node_action(container, @actions[action]) do
      :ok ->
        json(conn, 200, %{container: container, action: action, result: "ok"})

      :unchanged ->
        json(conn, 200, %{container: container, action: action, result: "sin cambios, ya estaba así"})

      {:error, :not_found} ->
        json(conn, 404, %{error: "no es un nodo del cluster", container: container})
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
