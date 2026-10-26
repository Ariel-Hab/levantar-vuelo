defmodule LevantarVuelo.ReplicasTest do
  use ExUnit.Case, async: true

  alias LevantarVuelo.Replicas

  @nodes [:"levantar@10.0.0.1", :"levantar@10.0.0.2", :"levantar@10.0.0.3", :"levantar@10.0.0.4"]

  # Es lo que fallaba con libring: para algunos vuelos devolvía menos nodos
  test "siempre devuelve la cantidad pedida de nodos distintos" do
    for i <- 1..10_000 do
      assert "fl_#{i}" |> Replicas.nodes_for(@nodes, 3) |> Enum.uniq() |> length() == 3
    end
  end

  test "todos los nodos eligen lo mismo, sin importar en qué orden ven a los demás" do
    for i <- 1..1_000 do
      assert Replicas.nodes_for("fl_#{i}", @nodes, 3) ==
               Replicas.nodes_for("fl_#{i}", Enum.reverse(@nodes), 3)
    end
  end

  test "si sale un nodo, solo cambian las réplicas de los vuelos que lo tenían" do
    [gone | rest] = @nodes

    for i <- 1..1_000, before = Replicas.nodes_for("fl_#{i}", @nodes, 3), gone not in before do
      assert Replicas.nodes_for("fl_#{i}", rest, 3) == before
    end
  end

  test "con menos nodos que el factor devuelve todos los que hay" do
    assert length(Replicas.nodes_for("fl_1", Enum.take(@nodes, 2), 3)) == 2
  end
end
