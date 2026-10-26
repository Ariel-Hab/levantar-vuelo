defmodule Control.Docker do
  @moduledoc """
  Cliente mínimo de la API de Docker (Docker Engine API), por el socket que
  docker-compose le monta a este contenedor en /var/run/docker.sock.

  Solo toca los contenedores del servicio `app` de este mismo proyecto de
  Compose, o sea, los nodos del cluster. Cualquier otro contenedor de la
  máquina (nginx, bases de datos de otros proyectos...) queda afuera.
  """

  @socket "/var/run/docker.sock"

  # Nombre base de los nodos Erlang (ver CLUSTER_NODE_BASENAME en config/runtime.exs)
  @node_basename "levantar"

  @doc """
  Los nodos del cluster, corriendo o parados. Uno por contenedor de `app`:
  `%{container: nombre, state: "running" | "exited" | ..., status: texto de Docker, node: nodo Erlang o nil}`.
  """
  def list_nodes do
    labels = ["com.docker.compose.project=#{project()}", "com.docker.compose.service=app"]

    %{status: 200, body: containers} =
      Req.get!(client(),
        url: "/containers/json",
        params: [all: true, filters: Jason.encode!(%{label: labels})]
      )

    containers
    |> Enum.map(&to_node/1)
    |> Enum.sort_by(& &1.container)
  end

  @doc """
  Le aplica una acción a un nodo:

    * `:kill`  — caída abrupta (SIGKILL), como si se cortara la luz
    * `:stop`  — apagado ordenado (SIGTERM): Erlang cierra la aplicación antes de salir
    * `:start` — levanta un contenedor parado

  Devuelve `:ok`, `:unchanged` si ya estaba así (start de uno corriendo, stop o
  kill de uno parado) o `{:error, :not_found}` si no es un nodo del cluster.
  """
  def node_action(container, action) when action in [:kill, :stop, :start] do
    if container in Enum.map(list_nodes(), & &1.container) do
      case Req.post!(client(), url: "/containers/#{container}/#{action}").status do
        204 -> :ok
        304 -> :unchanged
        409 -> :unchanged
      end
    else
      {:error, :not_found}
    end
  end

  # El proyecto de Compose de este mismo contenedor (por defecto, el nombre de
  # la carpeta: "checkpoint-2"). Docker usa el ID del contenedor como hostname.
  defp project do
    {:ok, hostname} = :inet.gethostname()
    %{status: 200, body: me} = Req.get!(client(), url: "/containers/#{hostname}/json")
    me["Config"]["Labels"]["com.docker.compose.project"]
  end

  defp to_node(container) do
    # Un contenedor parado no tiene IP (Docker devuelve "")
    ip =
      container["NetworkSettings"]["Networks"]
      |> Map.values()
      |> Enum.map(& &1["IPAddress"])
      |> Enum.find(&(&1 not in [nil, ""]))

    %{
      container: container["Names"] |> hd() |> String.trim_leading("/"),
      state: container["State"],
      status: container["Status"],
      node: ip && "#{@node_basename}@#{ip}"
    }
  end

  # La URL base no importa: con :unix_socket, Req se conecta al socket.
  # Sin reintentos: si Docker falla, que se vea.
  defp client do
    Req.new(base_url: "http://docker", unix_socket: @socket, retry: false)
  end
end
