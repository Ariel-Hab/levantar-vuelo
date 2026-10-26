defmodule LevantarVuelo.Replicas do
  @moduledoc """
  Decide en qué nodos se guardan las copias de cada vuelo y cuántas respuestas
  hacen falta para escribir y para leer (los quórums). La config está en
  config/config.exs (`:replication`).

  Para elegir los nodos usamos rendezvous hashing: cada nodo recibe un puntaje
  `hash({flight_id, nodo})` y las copias van a los `factor` nodos con mayor
  puntaje. Todos los nodos calculan lo mismo sin hablar entre ellos. Cuando
  entra o sale un nodo solo se mueven las copias de los vuelos que lo tenían
  (o que ahora lo eligen) entre sus primeros `factor`; el resto queda igual.

  Primero se probó libring (el hash ring que trae Horde), pero
  `HashRing.key_to_nodes/3` no da la vuelta al final del anillo: con 3 nodos,
  61 de cada 10.000 vuelos recibían 1 o 2 nodos en vez de 3.

  Con factor 3 y quórums de 2, una escritura confirmada y una lectura siempre
  comparten al menos un nodo (2 + 2 > 3): la lectura ve lo último confirmado.
  """

  @doc """
  Los nodos donde van las copias de este vuelo. Por defecto elige entre todos
  los nodos conectados: igual que Horde, cuenta cualquier nodo visible, así que
  un nodo de diagnóstico tiene que conectarse con `--hidden`.
  """
  def nodes_for(flight_id, nodes \\ [node() | Node.list()], count \\ factor()) do
    nodes
    |> Enum.sort_by(&{:erlang.phash2({flight_id, &1}), &1}, :desc)
    |> Enum.take(count)
  end

  def factor, do: config(:factor)
  def write_quorum, do: config(:write_quorum)
  def read_quorum, do: config(:read_quorum)
  def timeout, do: config(:timeout)

  defp config(key) do
    :levantar_vuelo
    |> Application.fetch_env!(:replication)
    |> Keyword.fetch!(key)
  end
end
