defmodule LevantarVuelo.ReplicaStoreTest do
  use ExUnit.Case, async: true

  alias LevantarVuelo.ReplicaStore

  # El ReplicaStore ya está corriendo (lo levantó la Application). En los tests
  # hay un solo nodo, con factor y quórums de 1 (config/config.exs). El
  # contenido de la copia no le importa al ReplicaStore: usamos átomos.
  setup context do
    {:ok, id: "rs_#{:erlang.phash2(context.test)}", nodes: [node()]}
  end

  test "un vuelo que nadie tiene se lee como nil", %{id: id, nodes: nodes} do
    assert ReplicaStore.fetch_latest(nodes, id) == {:ok, nil}
  end

  test "guarda la copia y devuelve la más nueva", %{id: id, nodes: nodes} do
    assert {:ok, _} = ReplicaStore.replicate(nodes, id, {1, 1}, :v1)
    assert {:ok, _} = ReplicaStore.replicate(nodes, id, {1, 2}, :v2)
    assert ReplicaStore.fetch_latest(nodes, id) == {:ok, {{1, 2}, :v2}}
  end

  test "una época nueva gana aunque tenga una versión menor", %{id: id, nodes: nodes} do
    {:ok, _} = ReplicaStore.replicate(nodes, id, {1, 5}, :viejo)
    assert {:ok, _} = ReplicaStore.replicate(nodes, id, {2, 3}, :nuevo)
    assert ReplicaStore.fetch_latest(nodes, id) == {:ok, {{2, 3}, :nuevo}}
  end

  test "rechaza escrituras de una época vieja (fencing)", %{id: id, nodes: nodes} do
    {:ok, _} = ReplicaStore.replicate(nodes, id, {2, 0}, :primario_nuevo)
    assert {:error, :stale_epoch} = ReplicaStore.replicate(nodes, id, {1, 9}, :primario_viejo)
    assert ReplicaStore.fetch_latest(nodes, id) == {:ok, {{2, 0}, :primario_nuevo}}
  end

  test "una copia repetida o más vieja de la misma época no pisa la que hay", %{id: id, nodes: nodes} do
    {:ok, _} = ReplicaStore.replicate(nodes, id, {1, 3}, :v3)
    assert {:ok, _} = ReplicaStore.replicate(nodes, id, {1, 3}, :v3)
    assert {:ok, _} = ReplicaStore.replicate(nodes, id, {1, 2}, :v2)
    assert ReplicaStore.fetch_latest(nodes, id) == {:ok, {{1, 3}, :v3}}
  end

  # Es lo que muestra GET /flights/:id/location como réplicas
  test "devuelve qué nodos guardaron la copia", %{id: id} do
    assert ReplicaStore.replicate([node(), :"nadie@ningun-lado"], id, {1, 1}, :v1) == {:ok, [node()]}
  end

  test "si no contestan suficientes nodos no confirma ni lee", %{id: id} do
    nadie = [:"nadie@ningun-lado"]
    assert ReplicaStore.replicate(nadie, id, {1, 1}, :v1) == {:error, :no_quorum}
    assert ReplicaStore.fetch_latest(nadie, id) == {:error, :no_quorum}
  end
end
