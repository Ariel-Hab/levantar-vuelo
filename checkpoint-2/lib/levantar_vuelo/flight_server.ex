defmodule LevantarVuelo.FlightServer do
  use GenServer

  alias LevantarVuelo.{Flight, SafeCall}

  # ---------------------------------------------------------------------------
  # API pública — las funciones que llaman los demás módulos
  # (igual que incrementar_like/obtener_likes del ejemplo de clase)
  # ---------------------------------------------------------------------------

  def start_link(flight_attrs) do
    GenServer.start_link(__MODULE__, flight_attrs, name: via(flight_attrs.id))
  end


  def get(flight_id),
    do: call(flight_id, :get)

  def reserve(flight_id, user_id, reservation_id),
    do: call(flight_id, {:reserve, user_id, reservation_id})

  def assign_seats(flight_id, reservation_id, wanted),
    do: call(flight_id, {:assign_seats, reservation_id, wanted})

  # Wrapper para manejar los calls y sus errores. Usa SafeCall (compartido con AlertIndex)
  # asi no mata el proceso que llama si el vuelo no existe, se cae, o su nodo se desconecta.
  defp call(flight_id, msg) do
    case SafeCall.call(via(flight_id), msg) do
      {:error, :noproc} -> {:error, :not_found}      # Para un vuelo, "no hay proceso" es "no existe"
      other -> other                                 # La respuesta, o :down / :nodedown / :timeout tal cual
    end
  end

  # ---------------------------------------------------------------------------
  # Callbacks de GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(flight_attrs) do
    flight = Flight.new(flight_attrs)

    # Programamos el cierre automático cuando venza el tiempo de oferta (F6).
    # Process.send_after manda el mensaje :offer_expired a este mismo proceso
    # después de N milisegundos. Si el proceso se cae y se reinicia, init
    # vuelve a calcular cuánto falta (o cierra en el momento si ya pasó).
    ms = ms_until(flight.offer_ends_at)
    Process.send_after(self(), :offer_expired, ms)

    {:ok, flight}
  end

  # Devuelve el estado completo del vuelo (para GET /flights/:id).
  # Lo envolvemos en {:ok, _} para que get devuelva siempre {:ok, _} | {:error, _}
  @impl true
  def handle_call(:get, _from, flight) do
    {:reply, {:ok, flight}, flight}
  end

  # Reserva un lugar. Overbooking permitido, por eso no falla aunque no haya stock.
  @impl true
  def handle_call({:reserve, user_id, reservation_id}, _from, flight) do
    case Flight.reserve(flight, user_id, reservation_id) do
      {:ok, rid, new_flight} ->
        {:reply, {:ok, rid}, new_flight}

      {:error, reason} ->
        {:reply, {:error, reason}, flight}
    end
  end

  # Elige asientos. Todo o nada: si no alcanza devuelve error con disponibilidad.
  # Si al asignar quedan 0 asientos, Flight cierra el vuelo automáticamente
  # y esta función detecta eso para mandar las notificaciones.
  @impl true
  def handle_call({:assign_seats, reservation_id, wanted}, _from, flight) do
    case Flight.assign_seats(flight, reservation_id, wanted) do
      {:ok, new_flight, assigned} ->
        # Si el vuelo se cerró al quedarse sin asientos, notificamos
        if match?({:closed, :sold_out}, new_flight.status) do
          notify_all(new_flight)
        end

        {:reply, {:ok, assigned}, new_flight}

      {:error, :unavailable, disponibilidad} ->
        {:reply, {:error, :unavailable, disponibilidad}, flight}

      {:error, reason} ->
        {:reply, {:error, reason}, flight}
    end
  end

  # El timer llegó a 0: se venció el tiempo de oferta (F6)
  @impl true
  def handle_info(:offer_expired, flight) do
    {closed_flight, cancelled_users} = Flight.close(flight, :expired)
    notify_users(cancelled_users, {:flight_closed, flight.id, :expired})
    {:noreply, closed_flight}
  end

  # ---------------------------------------------------------------------------
  # Helpers privados
  # ---------------------------------------------------------------------------

  # Registro por nombre: cada vuelo tiene un nombre único basado en su id.
  # Así cualquier parte del sistema puede mandarse mensajes sin tener el PID.
  # Es Horde.Registry, distribuido: el vuelo puede vivir en cualquier nodo del cluster
  # y el mensaje viaja solo hasta ahí. Además es lo que evita dos procesos para el
  # mismo vuelo: registrar un nombre que ya existe devuelve {:error, {:already_started, pid}}.
  defp via(flight_id) do
    {:via, Horde.Registry, {LevantarVuelo.Registry, flight_id}}
  end

  defp ms_until(datetime) do
    diff = DateTime.diff(datetime, DateTime.utc_now(), :millisecond)
    max(diff, 0)
  end

  defp notify_all(flight) do
    users =
      flight.reservations
      |> Map.values()
      |> Enum.map(& &1.user_id)
      |> Enum.uniq()

    notify_users(users, {:flight_closed, flight.id, :sold_out})
  end

  # Por ahora solo logueamos. Después acá irá el PubSub para SSE/WebSocket.
  defp notify_users(users, event) do
    Enum.each(users, fn user_id ->
      require Logger
      Logger.info("Notificando a #{user_id}: #{inspect(event)}")
    end)
  end
end
