defmodule LevantarVuelo.AlertIndex do
  use GenServer

  alias LevantarVuelo.{Alert, SafeCall}

  # ---------------------------------------------------------------------------
  # API pública
  # ---------------------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Agrega una alerta al índice. Devuelve {:ok, alert}."
  def add(%Alert{} = alert) do
    SafeCall.call(__MODULE__, {:add, alert})
  end

  @doc "Elimina una alerta por id."
  def remove(alert_id) do
    SafeCall.call(__MODULE__, {:remove, alert_id})
  end

  @doc """
  Devuelve {:ok, user_ids} de todos los que tienen una alerta que coincide con el vuelo.
  Esto se llama cuando se publica un vuelo nuevo (F3).
  """
  def matching_users(flight) do
    SafeCall.call(__MODULE__, {:matching_users, flight})
  end

  # ---------------------------------------------------------------------------
  # Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_) do
    # El estado es un mapa: %{alert_id => %Alert{}}
    {:ok, %{}}
  end

  @impl true
  def handle_call({:add, alert}, _from, alerts) do
    {:reply, {:ok, alert}, Map.put(alerts, alert.id, alert)}
  end

  @impl true
  def handle_call({:remove, id}, _from, alerts) do
    {:reply, :ok, Map.delete(alerts, id)}
  end

  @impl true
  def handle_call({:matching_users, flight}, _from, alerts) do
    # Filtramos las alertas que coinciden con el vuelo y devolvemos los user_ids
    users =
      alerts
      |> Map.values()
      |> Enum.filter(&Alert.matches?(&1, flight))
      |> Enum.map(& &1.user_id)
      |> Enum.uniq()

    {:reply, {:ok, users}, alerts}
  end
end
