defmodule LevantarVuelo.SSE do
  @moduledoc """
  Server-Sent Events: una respuesta HTTP que no se cierra. El servidor escribe
  un evento cada vez que hay algo que avisar, con este formato:

      event: flight_closed
      data: {"flight_id":"fl_1","reason":"sold_out"}

  (una línea en blanco cierra cada evento). Las líneas que empiezan con `:`
  son comentarios: el cliente las ignora. Ver docs/plan.md, sección 4.
  """
  import Plug.Conn

  alias LevantarVuelo.Notifier

  # Cada cuánto se manda un comentario si no hubo avisos
  @keepalive_ms 15_000

  @doc """
  Deja abierta la conexión y le escribe al usuario cada aviso que le llegue.
  Vuelve recién cuando el cliente se desconecta.
  """
  def stream(conn, user_id) do
    Notifier.subscribe(user_id)

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    # El cliente ve enseguida que se conectó, y a qué nodo
    write(conn, ": conectado a #{node()}\n\n")
  end

  @doc "Arma el texto de un evento SSE a partir de un aviso del Notifier."
  def encode({:flight_published, flight_id}),
    do: encode("flight_published", %{flight_id: flight_id})

  def encode({:flight_closed, flight_id, reason}),
    do: encode("flight_closed", %{flight_id: flight_id, reason: reason})

  defp encode(name, data), do: "event: #{name}\ndata: #{Jason.encode!(data)}\n\n"

  # Escribe y espera el próximo aviso. Si pasan @keepalive_ms sin avisos manda
  # un comentario: así nginx no corta la conexión por inactividad, y nos
  # enteramos si el cliente se fue (chunk da error) para terminar el proceso.
  defp write(conn, data) do
    case chunk(conn, data) do
      {:ok, conn} ->
        receive do
          {:notification, event} -> write(conn, encode(event))
        after
          @keepalive_ms -> write(conn, ": ping\n\n")
        end

      {:error, _closed} ->
        conn
    end
  end
end
