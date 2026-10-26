defmodule LevantarVuelo.Router do
  use Plug.Router

  require Logger

  alias LevantarVuelo.{Alert, AlertIndex, Flight, FlightServer}

  plug Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason

  plug :match
  plug :dispatch

  # --- Vuelos ---

  # POST /flights — publica un vuelo (F1) y notifica alertas coincidentes (F3)
  post "/flights" do
    %{"id" => id, "airline" => airline, "origin" => origin,
      "destination" => destination, "departs_at" => departs_at_str,
      "offer_ends_at" => offer_ends_at_str,
      "capacity" => %{"window" => w, "aisle" => a, "middle" => m}} = conn.body_params

    attrs = %{
      id: id,
      airline: airline,
      origin: origin,
      destination: destination,
      departs_at: parse_datetime!(departs_at_str),
      offer_ends_at: parse_datetime!(offer_ends_at_str),
      capacity: %{window: w, aisle: a, middle: m}
    }

    # Horde elige el nodo donde vive el vuelo (puede ser otro, no el que recibió el pedido).
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

        notify_flight_published(users, id)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(201, Jason.encode!(%{flight_id: id, notified_users: length(users)}))

      {:error, {:already_started, _}} ->
        send_resp(conn, 409, Jason.encode!(%{error: "vuelo ya existe"}))

      # Horde no pudo ubicar el vuelo (sin quórum, sin nodos vivos...): falla transitoria
      {:error, reason} ->
        error_response(conn, reason)
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

  # --- Alertas ---

  # POST /alerts — crea una alerta (F2)
  post "/alerts" do
    %{"id" => id, "user_id" => user_id,
      "origin" => origin, "destination" => destination} = conn.body_params

    alert = Alert.new(%{
      id: id,
      user_id: user_id,
      origin: origin,
      destination: destination,
      date: parse_date(conn.body_params["date"]),
      month: parse_month(conn.body_params["month"])
    })

    case AlertIndex.add(alert) do
      {:ok, _} -> json(conn, 201, %{alert_id: id})
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
    %{"reservation_id" => rid, "user_id" => user_id} = conn.body_params

    case FlightServer.reserve(flight_id, user_id, rid) do
      {:ok, rid} ->
        json(conn, 201, %{reservation_id: rid})

      {:error, reason} ->
        error_response(conn, reason)
    end
  end

  # POST /flights/:flight_id/reservations/:rid/seats — elige asientos (F5)
  post "/flights/:flight_id/reservations/:rid/seats" do
    wanted = conn.body_params["seats"] |> Enum.map(&String.to_atom/1)

    case FlightServer.assign_seats(flight_id, rid, wanted) do
      {:ok, assigned} ->
        json(conn, 200, %{assigned: Enum.map(assigned, &to_string/1)})

      {:error, :unavailable, disponibilidad} ->
        json(conn, 409, %{error: "sin disponibilidad", available: disponibilidad})

      {:error, reason} ->
        error_response(conn, reason)
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

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
  # Son fallas transitorias: el cliente puede reintentar (por eso reserve
  # tiene que ser idempotente).
  defp error_response(conn, reason)
       when reason in [:noproc, :down, :nodedown, :timeout, :quorum_not_met, :no_alive_nodes],
    do: json(conn, 503, %{error: "servicio no disponible, reintentá", reason: reason})

  # El resto son errores de negocio (ej. :reservation_not_found)
  defp error_response(conn, reason), do: json(conn, 422, %{error: inspect(reason)})

  defp parse_datetime!(str) do
    {:ok, dt, _} = DateTime.from_iso8601(str)
    dt
  end

  defp parse_date(nil), do: nil
  defp parse_date(str), do: Date.from_iso8601!(str)

  defp parse_month(nil), do: nil
  defp parse_month(%{"year" => y, "month" => m}), do: {y, m}

  defp notify_flight_published(users, flight_id) do
    require Logger
    Enum.each(users, fn uid ->
      Logger.info("Notificando a #{uid}: nuevo vuelo #{flight_id}")
    end)
  end
end
