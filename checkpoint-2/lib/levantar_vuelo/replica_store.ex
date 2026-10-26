defmodule LevantarVuelo.ReplicaStore do
  @moduledoc """
  Guarda copias de vuelos, de este nodo y de otros. Hay uno por nodo y es
  pasivo: solo guarda y devuelve. Lo usa el FlightServer para que el estado de
  un vuelo sobreviva a la caída de su nodo (ver docs/plan.md, sección 3).

  Cada copia lleva un sello `{época, versión}`. La época sube cada vez que un
  FlightServer nuevo toma el control del vuelo; la versión, en cada cambio.
  Los sellos se comparan como tuplas: primero la época y después la versión.

  Fencing: si llega una copia con una época MENOR a la que ya se tiene, se
  rechaza con `:stale_epoch`. Eso deja afuera a un primario viejo que todavía
  cree que manda.
  """
  use GenServer

  alias LevantarVuelo.Replicas

  # ---------------------------------------------------------------------------
  # API pública — la llama el FlightServer, desde el nodo donde esté
  # ---------------------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Manda la copia al ReplicaStore de cada nodo y espera las respuestas.
  Devuelve `{:ok, nodos_que_la_guardaron}` si son al menos `write_quorum`,
  `{:error, :stale_epoch}` si alguno ya vio una época más nueva, o
  `{:error, :no_quorum}` si contestaron menos.
  """
  def replicate(nodes, flight_id, stamp, flight) do
    with {:ok, saved} <- put_all(nodes, flight_id, stamp, flight) do
      if length(saved) >= Replicas.write_quorum(), do: {:ok, saved}, else: {:error, :no_quorum}
    end
  end

  @doc """
  Como replicate/4 pero sin exigir quórum: para completar copias que faltan.
  Devuelve `{:ok, nodos_que_la_guardaron}` o `{:error, :stale_epoch}`.
  """
  def put_all(nodes, flight_id, stamp, flight) do
    # multi_call manda el pedido a todos los nodos a la vez y espera hasta el
    # timeout. Los nodos caídos o sin ReplicaStore (todavía arrancando) no contestan.
    {replies, _sin_respuesta} =
      GenServer.multi_call(nodes, __MODULE__, {:put, flight_id, stamp, flight}, Replicas.timeout())

    if Enum.any?(replies, &match?({_node, {:error, :stale_epoch}}, &1)) do
      {:error, :stale_epoch}
    else
      {:ok, Enum.map(replies, fn {node, :ok} -> node end)}
    end
  end

  @doc """
  Pide la copia del vuelo a cada nodo. Si contestan al menos `read_quorum`,
  devuelve `{:ok, {sello, flight}}` con la más nueva, o `{:ok, nil}` si
  ninguno la tiene. Si contestan menos, `{:error, :no_quorum}`.
  """
  def fetch_latest(nodes, flight_id) do
    {replies, _sin_respuesta} =
      GenServer.multi_call(nodes, __MODULE__, {:get, flight_id}, Replicas.timeout())

    if length(replies) >= Replicas.read_quorum() do
      latest =
        for({_node, {:ok, copy}} <- replies, do: copy)
        |> Enum.max_by(fn {stamp, _flight} -> stamp end, &>=/2, fn -> nil end)

      {:ok, latest}
    else
      {:error, :no_quorum}
    end
  end

  # ---------------------------------------------------------------------------
  # Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(copies) do
    # El estado es un mapa: %{flight_id => {{época, versión}, %Flight{}}}
    {:ok, copies}
  end

  @impl true
  def handle_call({:put, flight_id, {epoch, _version} = stamp, flight}, _from, copies) do
    case copies do
      # Ya vio un primario más nuevo para este vuelo: rechaza (fencing)
      %{^flight_id => {{seen_epoch, _}, _}} when epoch < seen_epoch ->
        {:reply, {:error, :stale_epoch}, copies}

      # Ya tiene esta copia, o una más nueva del mismo primario: no cambia nada
      %{^flight_id => {seen_stamp, _}} when stamp <= seen_stamp ->
        {:reply, :ok, copies}

      _ ->
        {:reply, :ok, Map.put(copies, flight_id, {stamp, flight})}
    end
  end

  def handle_call({:get, flight_id}, _from, copies) do
    {:reply, Map.fetch(copies, flight_id), copies}
  end
end
