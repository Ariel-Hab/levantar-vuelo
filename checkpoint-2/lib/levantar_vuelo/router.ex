defmodule LevantarVuelo.Router do
  use Plug.Router

  require Logger

  alias LevantarVuelo.{Alert, AlertIndex, Flight, FlightServer, Notifier, Params, SSE}

  plug Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason

  plug :match
  plug :dispatch

  # --- Vuelos ---

  # POST /flights — publica un vuelo (F1) y notifica alertas coincidentes (F3)
  post "/flights" do
    case Params.flight(conn.body_params) do
      {:ok, attrs} -> publish_flight(conn, attrs)
      {:error, message} -> json(conn, 400, %{error: message})
    end
  end

  # GET /flights/:id — estado y disponibilidad del vuelo
  get "/flights/:id" do
    case FlightServer.get(id) do
      {:ok, flight} ->
        body = %{
          id: flight.id,
          status: inspect(flight.status),
          available: flight.available,
          reservations_count: map_size(flight.reservations)
        }
        json(conn, 200, body)

      {:error, reason} ->
        error_response(conn, reason)
    end
  end

  # GET /flights/:id/location — en qué contenedor vive el vuelo y dónde están
  # sus copias. Para pruebas y demos: saber qué contenedor matar.
  get "/flights/:id/location" do
    case FlightServer.location(id) do
      {:ok, info} ->
        body = %{
          flight_id: id,
          node: info.node,
          container: container_name(info.node),
          recovering: info.recovering,
          epoch: info.epoch,
          version: info.version,
          replicas: Enum.map(info.replicas, &%{node: &1, container: container_name(&1)})
        }
        json(conn, 200, body)

      {:error, reason} ->
        error_response(conn, reason)
    end
  end

  # --- Alertas ---

  # POST /alerts — crea una alerta (F2)
  #
  # En estos `with`, un {:error, texto} viene de Params (body inválido: 400) y
  # un {:error, átomo} viene del servicio (ver error_response).
  post "/alerts" do
    with {:ok, attrs} <- Params.alert(conn.body_params),
         {:ok, _} <- AlertIndex.add(Alert.new(attrs)) do
      json(conn, 201, %{alert_id: attrs.id})
    else
      {:error, message} when is_binary(message) -> json(conn, 400, %{error: message})
      {:error, reason} -> error_response(conn, reason)
    end
  end

  # DELETE /alerts/:id — elimina una alerta
  delete "/alerts/:id" do
    case AlertIndex.remove(id) do
      :ok -> send_resp(conn, 204, "")
      {:error, reason} -> error_response(conn, reason)
    end
  end

  # --- Reservas ---

  # POST /flights/:flight_id/reservations — reserva un lugar (F4)
  post "/flights/:flight_id/reservations" do
    with {:ok, rid, user_id} <- Params.reservation(conn.body_params),
         {:ok, rid} <- FlightServer.reserve(flight_id, user_id, rid) do
      json(conn, 201, %{reservation_id: rid})
    else
      {:error, message} when is_binary(message) -> json(conn, 400, %{error: message})
      {:error, reason} -> error_response(conn, reason)
    end
  end

  # POST /flights/:flight_id/reservations/:rid/seats — elige asientos (F5)
  post "/flights/:flight_id/reservations/:rid/seats" do
    with {:ok, wanted} <- Params.seats(conn.body_params),
         {:ok, assigned} <- FlightServer.assign_seats(flight_id, rid, wanted) do
      json(conn, 200, %{assigned: Enum.map(assigned, &to_string/1)})
    else
      {:error, message} when is_binary(message) ->
        json(conn, 400, %{error: message})

      {:error, :unavailable, disponibilidad} ->
        json(conn, 409, %{error: "sin disponibilidad", available: disponibilidad})

      {:error, reason} ->
        error_response(conn, reason)
    end
  end

  # --- Notificaciones ---

  # GET /users/:user_id/events — avisos al usuario por SSE (F3 y cierres de
  # vuelo). La respuesta queda abierta: probar con `curl -N`.
  get "/users/:user_id/events" do
    SSE.stream(conn, user_id)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Horde elige el nodo donde vive el vuelo (puede ser otro, no el que recibió el pedido).
  defp publish_flight(conn, %{id: id} = attrs) do
    case Horde.DynamicSupervisor.start_child(LevantarVuelo.DynamicSupervisor, {FlightServer, attrs}) do
      {:ok, _pid} ->
        # F3: busca usuarios con alertas que coinciden y los notifica.
        # El vuelo ya está creado: si no podemos consultar las alertas no
        # fallamos el POST, solo no notificamos (degradación).
        # Se matchea contra los datos del pedido (Flight.new) y no contra el
        # FlightServer: si el vuelo nació en otro nodo, el registro distribuido
        # tarda un instante en enterarse y un FlightServer.get podría dar :not_found.
        users =
          case AlertIndex.matching_users(Flight.new(attrs)) do
            {:ok, users} ->
              users

            {:error, reason} ->
              Logger.warning("No se notificaron las alertas del vuelo #{id}: #{inspect(reason)}")
              []
          end

        Notifier.notify(users, {:flight_published, id})
        json(conn, 201, %{flight_id: id, notified_users: length(users)})

      {:error, {:already_started, _}} ->
        json(conn, 409, %{error: "vuelo ya existe"})

      # Horde no pudo ubicar el vuelo (sin quórum, sin nodos vivos...): falla transitoria
      {:error, reason} ->
        error_response(conn, reason)
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  # Traduce los errores de los servicios a respuestas HTTP, en un solo lugar.
  defp error_response(conn, :not_found), do: json(conn, 404, %{error: "vuelo no encontrado"})
  defp error_response(conn, :flight_closed), do: json(conn, 410, %{error: "vuelo cerrado"})

  # :noproc viene de AlertIndex (lo está reiniciando el supervisor),
  # :down, :nodedown y :timeout de cualquier servicio. :quorum_not_met y
  # :no_alive_nodes vienen de Horde (el nodo quedó aislado o no hay nodos).
  # :no_quorum y :stale_epoch vienen de la réplica del FlightServer (no se
  # pudo confirmar en quórum, o el vuelo cambió de primario), y :overloaded
  # de su límite de mailbox.
  # Son fallas transitorias: el cliente puede reintentar (por eso reserve y
  # assign_seats son idempotentes).
  defp error_response(conn, reason)
       when reason in [:noproc, :down, :nodedown, :timeout, :quorum_not_met, :no_alive_nodes,
                       :no_quorum, :stale_epoch, :overloaded],
    do: json(conn, 503, %{error: "servicio no disponible, reintentá", reason: reason})

  # El resto son errores de negocio (ej. :reservation_not_found)
  defp error_response(conn, reason), do: json(conn, 422, %{error: inspect(reason)})

  # Los nodos se llaman "levantar@<IP del contenedor>". El DNS interno de Docker
  # también resuelve al revés, de IP a "<contenedor>.<red>"
  # (ej. "checkpoint-2-app-1.checkpoint-2_default"). Fuera de Docker (tests,
  # mix run) el nombre del nodo no tiene IP y devuelve nil.
  #
  # Se usa :inet_res (le pregunta directo al DNS) y no :inet.gethostbyaddr,
  # que mira antes /etc/hosts: ahí la IP propia del contenedor figura con su
  # ID (ej. "ed50c00a13b2"), no con su nombre.
  defp container_name(node) do
    with [_, host] <- String.split(to_string(node), "@"),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(host)),
         {:ok, {:hostent, name, _aliases, _type, _len, _addrs}} <- :inet_res.gethostbyaddr(ip) do
      name |> to_string() |> String.split(".") |> hd()
    else
      _ -> nil
    end
  end
end
