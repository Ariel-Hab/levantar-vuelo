defmodule LevantarVuelo.AlertIndex do
  @moduledoc """
  Índice de alertas replicado en todos los nodos (AP).

  Las alertas viven en un DeltaCrdt de tipo AWLWWMap (Add-Wins, Last-Write-Wins):
  un mapa `alert_id => %Alert{}` que se replica solo. Cada nodo tiene la copia
  completa. Crear o borrar una alerta escribe en la copia local y responde
  enseguida; DeltaCrdt manda solo el cambio (el "delta") a los demás nodos en
  segundo plano, cada 100 ms. Si dos nodos tocan la misma alerta a la vez:

    * uno la borra y otro la escribe → gana la escritura (add-wins)
    * los dos la escriben distinto → gana la más nueva (last-write-wins)

  Consecuencia: una alerta recién creada en un nodo puede tardar un instante en
  verse desde otro. Si justo en ese instante se publica un vuelo que coincide,
  ese usuario no recibe el aviso. Lo aceptamos porque es un aviso, no una venta.
  A cambio, las alertas siguen funcionando aunque se caigan otros nodos, y un
  nodo que entra al cluster recibe todas las que ya existían.
  """
  use Supervisor

  alias LevantarVuelo.{Alert, CrdtNeighbours, SafeCall}

  # Nombre del DeltaCrdt en cada nodo. Es el mismo en todos: así se encuentran.
  @crdt LevantarVuelo.AlertIndex.Crdt

  # ---------------------------------------------------------------------------
  # API pública
  # ---------------------------------------------------------------------------

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc "Agrega una alerta al índice. Devuelve {:ok, alert}."
  def add(%Alert{} = alert) do
    SafeCall.run(fn ->
      DeltaCrdt.put(@crdt, alert.id, alert)
      {:ok, alert}
    end)
  end

  @doc "Elimina una alerta por id."
  def remove(alert_id) do
    SafeCall.run(fn ->
      DeltaCrdt.delete(@crdt, alert_id)
      :ok
    end)
  end

  @doc """
  Devuelve {:ok, user_ids} de todos los que tienen una alerta que coincide con el vuelo.
  Esto se llama cuando se publica un vuelo nuevo (F3). Lee la copia local, no
  consulta a los otros nodos.
  """
  def matching_users(flight) do
    SafeCall.run(fn ->
      users =
        DeltaCrdt.to_map(@crdt)
        |> Map.values()
        |> Enum.filter(&Alert.matches?(&1, flight))
        |> Enum.map(& &1.user_id)
        |> Enum.uniq()

      {:ok, users}
    end)
  end

  # ---------------------------------------------------------------------------
  # Supervisor
  # ---------------------------------------------------------------------------

  @impl true
  def init(_) do
    children = [
      {DeltaCrdt, crdt: DeltaCrdt.AWLWWMap, name: @crdt, sync_interval: 100},
      {CrdtNeighbours, @crdt}
    ]

    # rest_for_one: si se cae el CRDT se reinicia también CrdtNeighbours, porque
    # el CRDT nuevo arranca vacío y sin vecinos. Cuando los recibe, los otros
    # nodos le mandan todas las alertas. (Con un solo nodo, se pierden.)
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
