defmodule LevantarVuelo.FlightServer do
  use GenServer

  require Logger

  alias LevantarVuelo.{Flight, ReplicaStore, Replicas, SafeCall}

  # Cada cuánto se reintenta algo que falló por falta de quórum de réplicas
  @retry_ms 1_000

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

  # En qué nodo vive el proceso del vuelo y cómo está su réplica (para pruebas)
  def location(flight_id),
    do: call(flight_id, :location)

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
  #
  # El estado es un mapa:
  #   flight:   el %Flight{} (nil mientras no se pudo recuperar)
  #   attrs:    los datos con los que se creó el vuelo (Horde los vuelve a pasar al reiniciarlo)
  #   epoch:    la época de este primario (ver ReplicaStore)
  #   version:  el número del último cambio
  #   replicas: los nodos que confirmaron tener la copia de esta versión

  @impl true
  def init(flight_attrs) do
    # Para enterarnos si entra o sale un nodo: puede cambiar dónde van las copias
    :net_kernel.monitor_nodes(true)

    state = %{flight: nil, attrs: flight_attrs, epoch: 0, version: 0, replicas: []}

    # Recuperar el vuelo implica hablar con otros nodos. Lo hacemos en
    # handle_continue, apenas termina init, para no frenar al supervisor que
    # nos está arrancando. Los pedidos que lleguen mientras tanto esperan en el mailbox.
    {:ok, state, {:continue, :recover}}
  end

  @impl true
  def handle_continue(:recover, state), do: recover(state)

  # Dónde vive el vuelo y cómo está su réplica (GET /flights/:id/location).
  # Contesta aunque el vuelo se esté recuperando: sirve para ver dónde quedó trabado.
  @impl true
  def handle_call(:location, _from, state) do
    info = %{
      node: node(),
      recovering: is_nil(state.flight),
      epoch: state.epoch,
      version: state.version,
      replicas: state.replicas
    }

    {:reply, {:ok, info}, state}
  end

  # Mientras no se pudo recuperar el vuelo no atiende pedidos: 503, reintentá
  def handle_call(_msg, _from, %{flight: nil} = state) do
    {:reply, {:error, :no_quorum}, state}
  end

  # Devuelve el estado completo del vuelo (para GET /flights/:id).
  # Lo envolvemos en {:ok, _} para que get devuelva siempre {:ok, _} | {:error, _}
  def handle_call(:get, _from, state) do
    {:reply, {:ok, state.flight}, state}
  end

  # Reserva un lugar. Overbooking permitido, por eso no falla aunque no haya stock.
  def handle_call({:reserve, user_id, reservation_id}, _from, state) do
    with {:ok, rid, new_flight} <- Flight.reserve(state.flight, user_id, reservation_id),
         {:ok, state} <- commit(state, new_flight) do
      {:reply, {:ok, rid}, state}
    else
      {:not_committed, reason, state} -> not_committed(reason, state)
      # Error de negocio de Flight (vuelo cerrado, id de reserva de otro usuario)
      error -> {:reply, error, state}
    end
  end

  # Elige asientos. Todo o nada: si no alcanza devuelve error con disponibilidad.
  # Si al asignar quedan 0 asientos, Flight cierra el vuelo automáticamente
  # y esta función detecta eso para mandar las notificaciones.
  def handle_call({:assign_seats, reservation_id, wanted}, _from, state) do
    with {:ok, new_flight, assigned} <- Flight.assign_seats(state.flight, reservation_id, wanted),
         {:ok, state} <- commit(state, new_flight) do
      # Si el vuelo se cerró al quedarse sin asientos, notificamos
      if match?({:closed, :sold_out}, new_flight.status) do
        notify_all(new_flight)
      end

      {:reply, {:ok, assigned}, state}
    else
      {:not_committed, reason, state} -> not_committed(reason, state)
      # Error de negocio de Flight (sin disponibilidad, vuelo cerrado, reserva inexistente)
      error -> {:reply, error, state}
    end
  end

  # El timer llegó a 0: se venció el tiempo de oferta (F6)
  @impl true
  def handle_info(:offer_expired, %{flight: %{status: :open}} = state) do
    {closed_flight, cancelled_users} = Flight.close(state.flight, :expired)

    case commit(state, closed_flight) do
      {:ok, state} ->
        notify_users(cancelled_users, {:flight_closed, closed_flight.id, :expired})
        {:noreply, state}

      # Sin quórum el vuelo sigue abierto hasta que se pueda confirmar el cierre
      {:not_committed, :no_quorum, state} ->
        Process.send_after(self(), :offer_expired, @retry_ms)
        {:noreply, state}

      {:not_committed, :stale_epoch, state} ->
        {:stop, {:shutdown, :stale_epoch}, state}
    end
  end

  # Ya estaba cerrado (se agotó antes de que venza la oferta): no hay nada que hacer
  def handle_info(:offer_expired, state), do: {:noreply, state}

  # Entró o salió un nodo: puede cambiar dónde van las copias de este vuelo.
  # Un nodo que se cae deja de contar como réplica: si vuelve, vuelve vacío.
  def handle_info({:nodedown, node}, state) do
    Process.send_after(self(), :check_replicas, @retry_ms)
    {:noreply, %{state | replicas: List.delete(state.replicas, node)}}
  end

  def handle_info({:nodeup, _node}, state) do
    Process.send_after(self(), :check_replicas, @retry_ms)
    {:noreply, state}
  end

  def handle_info(:check_replicas, %{flight: nil} = state), do: {:noreply, state}

  # Si a algún nodo que debería tener la copia le falta, se la mandamos (con el
  # mismo sello: no es un cambio del vuelo). Sin esto, al escalar a más nodos
  # o al volver un nodo caído, una recuperación podría leer justo de nodos sin copia.
  def handle_info(:check_replicas, state) do
    target = Replicas.nodes_for(state.flight.id)

    case target -- state.replicas do
      [] ->
        {:noreply, state}

      missing ->
        case ReplicaStore.put_all(missing, state.flight.id, {state.epoch, state.version}, state.flight) do
          {:ok, saved} -> {:noreply, track_replicas(state, state.replicas ++ saved, target)}
          {:error, :stale_epoch} -> {:stop, {:shutdown, :stale_epoch}, state}
        end
    end
  end

  def handle_info(:recover, state), do: recover(state)

  # ---------------------------------------------------------------------------
  # Réplica (ver docs/plan.md, sección 3)
  # ---------------------------------------------------------------------------

  # Failover. Corre siempre al arrancar: para un vuelo nuevo ninguna réplica
  # lo tiene, y arranca de cero con los attrs.
  #   1. Lee las copias de quórum de nodos y se queda con la más nueva.
  #   2. Sube la época: este proceso pasa a ser el primario vigente.
  #   3. "Reclama" el vuelo: copia el estado con la época nueva a quórum. Desde
  #      ahí, esas réplicas rechazan las escrituras de cualquier primario anterior.
  defp recover(%{attrs: attrs} = state) do
    target = Replicas.nodes_for(attrs.id)

    with {:ok, latest} <- ReplicaStore.fetch_latest(target, attrs.id),
         {{epoch, version}, flight} = latest || {{0, 0}, Flight.new(attrs)},
         {:ok, saved} <- ReplicaStore.replicate(target, attrs.id, {epoch + 1, version}, flight) do
      Logger.info("Vuelo #{attrs.id} activo en #{node()}: época #{epoch + 1}, versión #{version}")
      schedule_offer_end(flight)
      state = %{state | flight: flight, epoch: epoch + 1, version: version}
      {:noreply, track_replicas(state, saved, target)}
    else
      # CP: sin quórum no sabemos si tenemos lo último. Hasta que vuelva, contesta 503.
      {:error, :no_quorum} ->
        Logger.warning("Vuelo #{attrs.id}: sin quórum para recuperarlo, reintento en #{@retry_ms} ms")
        Process.send_after(self(), :recover, @retry_ms)
        {:noreply, state}

      # Otro primario reclamó el vuelo con una época más nueva mientras tanto
      {:error, :stale_epoch} ->
        {:stop, {:shutdown, :stale_epoch}, state}
    end
  end

  # Confirma un estado nuevo del vuelo: primero lo copia a quórum de réplicas y
  # recién ahí lo adopta. Devuelve {:ok, state} o {:not_committed, motivo, state}.
  #
  # Si el estado no cambió (el mismo `flight` en los dos lados, ej. una reserva
  # reintentada) no hay nada que copiar.
  defp commit(%{flight: flight} = state, flight), do: {:ok, state}

  defp commit(state, new_flight) do
    version = state.version + 1
    target = Replicas.nodes_for(new_flight.id)

    case ReplicaStore.replicate(target, new_flight.id, {state.epoch, version}, new_flight) do
      {:ok, saved} ->
        {:ok, track_replicas(%{state | flight: new_flight, version: version}, saved, target)}

      # El cambio NO se adopta. La versión avanza igual: alguna réplica pudo
      # guardarlo, y el próximo cambio no puede reusar ese número con otro contenido.
      {:error, reason} ->
        {:not_committed, reason, %{state | version: version}}
    end
  end

  # Anota qué nodos tienen la copia actual. Si a alguno de los que deberían
  # tenerla le falta (ej. un nodo recién conectado que todavía no levantó su
  # ReplicaStore), se reintenta más tarde con :check_replicas.
  defp track_replicas(state, saved, target) do
    if target -- saved != [] do
      Process.send_after(self(), :check_replicas, @retry_ms)
    end

    %{state | replicas: saved}
  end

  # Respuesta de un handle_call cuyo cambio no se pudo confirmar:
  #   :no_quorum   → 503 y sigue; el cliente puede reintentar.
  #   :stale_epoch → hay un primario más nuevo para este vuelo y este se retira.
  #                  Con {:shutdown, _} Horde no lo reinicia.
  defp not_committed(:no_quorum, state), do: {:reply, {:error, :no_quorum}, state}

  defp not_committed(:stale_epoch, state),
    do: {:stop, {:shutdown, :stale_epoch}, {:error, :stale_epoch}, state}

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

  # Programamos el cierre automático cuando venza el tiempo de oferta (F6).
  # Process.send_after manda el mensaje :offer_expired a este mismo proceso
  # después de N milisegundos. Si el vuelo se recupera (en este nodo o en otro),
  # se vuelve a calcular cuánto falta, o cierra en el momento si ya pasó.
  defp schedule_offer_end(%Flight{status: :open} = flight) do
    Process.send_after(self(), :offer_expired, ms_until(flight.offer_ends_at))
  end

  defp schedule_offer_end(_closed_flight), do: :ok

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
      Logger.info("Notificando a #{user_id}: #{inspect(event)}")
    end)
  end
end
