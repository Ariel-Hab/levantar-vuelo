defmodule LevantarVuelo.CrdtNeighbours do
  @moduledoc """
  Le dice a un DeltaCrdt con quién sincronizarse: la misma CRDT (mismo nombre)
  en cada uno de los otros nodos del cluster.

  DeltaCrdt no descubre nodos solo. Hay que pasarle la lista de vecinos con
  `DeltaCrdt.set_neighbours/2`, y volver a pasarla cada vez que entra o se va
  un nodo. Este proceso se entera de eso con `:net_kernel.monitor_nodes/1`.
  """
  use GenServer

  def start_link(crdt_name) do
    GenServer.start_link(__MODULE__, crdt_name)
  end

  @impl true
  def init(crdt_name) do
    # A partir de acá este proceso recibe {:nodeup, nodo} y {:nodedown, nodo}
    :net_kernel.monitor_nodes(true)
    set_neighbours(crdt_name)
    {:ok, crdt_name}
  end

  @impl true
  def handle_info({event, _node}, crdt_name) when event in [:nodeup, :nodedown] do
    set_neighbours(crdt_name)
    {:noreply, crdt_name}
  end

  # Un vecino es {nombre, nodo}: el proceso registrado con ese nombre en ese nodo.
  # Si en un nodo todavía no arrancó (o ya no está), DeltaCrdt no falla: lo vuelve
  # a intentar en cada sincronización hasta que aparece.
  defp set_neighbours(crdt_name) do
    DeltaCrdt.set_neighbours(crdt_name, Enum.map(Node.list(), &{crdt_name, &1}))
  end
end
