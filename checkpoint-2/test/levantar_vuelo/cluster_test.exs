defmodule LevantarVuelo.ClusterTest do
  # Tests multi-nodo: cada test levanta su propio cluster de 3 VMs con
  # TestCluster. Son más lentos que el resto (unos segundos cada uno).
  use ExUnit.Case, async: false

  alias LevantarVuelo.{Alert, AlertIndex, FlightServer, TestCluster}
  alias LevantarVuelo.TestCluster.Listener

  @moduletag :cluster
  @moduletag timeout: 120_000

  setup do
    peers = TestCluster.start(3)
    on_exit(fn -> Enum.each(peers, fn {peer, _} -> TestCluster.stop(peer) end) end)
    {:ok, peers: peers}
  end

  test "el vuelo sobrevive a la caída de su nodo con todas las compras", %{peers: peers} do
    [{p1, _} | _] = peers
    id = create_flight(p1, %{window: 2, aisle: 2, middle: 2})

    {:ok, "r1"} = TestCluster.call(p1, FlightServer, :reserve, [id, "u1", "r1"])
    {:ok, asientos} = TestCluster.call(p1, FlightServer, :assign_seats, [id, "r1", [:window, :aisle]])

    # Se cae el nodo donde vive el vuelo
    {:ok, %{node: primary, epoch: 1}} = TestCluster.call(p1, FlightServer, :location, [id])
    {dead, _} = List.keyfind(peers, primary, 1)
    TestCluster.stop(dead)

    # Otro nodo lo levanta desde las réplicas: misma compra y época nueva
    {survivor, _} = Enum.find(peers, fn {_, node} -> node != primary end)

    flight =
      eventually(fn ->
        case TestCluster.call(survivor, FlightServer, :get, [id]) do
          {:ok, flight} -> flight
          _ -> nil
        end
      end)

    assert flight.reservations["r1"].status == :confirmed
    assert flight.reservations["r1"].seats == asientos
    assert flight.available == %{window: 1, aisle: 1, middle: 2}

    assert {:ok, %{epoch: 2, node: new_primary}} = TestCluster.call(survivor, FlightServer, :location, [id])
    assert new_primary != primary
  end

  test "con un solo nodo vivo no se confirma nada (CP)", %{peers: peers} do
    [{p1, _}, {p2, _}, {p3, _}] = peers
    id = create_flight(p1, %{window: 2, aisle: 2, middle: 2})
    {:ok, "r1"} = TestCluster.call(p1, FlightServer, :reserve, [id, "u1", "r1"])

    TestCluster.stop(p2)
    TestCluster.stop(p3)

    # Esté donde esté el vuelo, una escritura con un solo nodo no llega a quórum
    eventually(fn ->
      TestCluster.call(p1, FlightServer, :reserve, [id, "u2", "r2"]) == {:error, :no_quorum}
    end)
  end

  test "una alerta creada en un nodo se ve desde los otros", %{peers: peers} do
    [{p1, _}, _, {p3, _}] = peers
    alert = Alert.new(%{id: "a1", user_id: "u1", origin: "EZE", destination: "MAD", date: nil, month: nil})
    {:ok, _} = TestCluster.call(p1, AlertIndex, :add, [alert])

    vuelo = %{origin: "EZE", destination: "MAD", departs_at: ~U[2026-12-20 22:00:00Z]}
    eventually(fn -> TestCluster.call(p3, AlertIndex, :matching_users, [vuelo]) == {:ok, ["u1"]} end)
  end

  test "el aviso llega al usuario conectado a otro nodo que el del vuelo", %{peers: peers} do
    [{p1, _} | _] = peers
    id = create_flight(p1, %{window: 1, aisle: 0, middle: 0})
    {:ok, %{node: primary}} = TestCluster.call(p1, FlightServer, :location, [id])

    # El usuario escucha desde un nodo distinto al del vuelo
    {listener, _} = Enum.find(peers, fn {_, node} -> node != primary end)
    :ok = TestCluster.call(listener, Listener, :start, ["u1"])

    # Compra el único asiento: el vuelo se agota y avisa desde su nodo
    {:ok, "r1"} = TestCluster.call(p1, FlightServer, :reserve, [id, "u1", "r1"])
    {:ok, _} = TestCluster.call(p1, FlightServer, :assign_seats, [id, "r1", [:window]])

    eventually(fn ->
      {:flight_closed, id, :sold_out} in TestCluster.call(listener, Listener, :received, ["u1"])
    end)
  end

  # Crea el vuelo desde el peer dado. Horde elige en qué nodo vive.
  #
  # Espera un segundo antes de devolver: Horde le cuenta a los otros nodos qué
  # procesos tiene cada 100 ms, y si el nodo del vuelo se cae antes, los demás
  # no saben que existía y nadie lo reinicia (límite aceptado, ver
  # docs/tradeoffs.md). Sin la espera, los tests que matan nodos fallan seguido.
  defp create_flight(peer, capacity) do
    id = "fl_cluster_#{System.unique_integer([:positive])}"

    attrs = %{
      id: id,
      airline: "AR",
      origin: "EZE",
      destination: "MAD",
      departs_at: ~U[2026-12-20 22:00:00Z],
      offer_ends_at: ~U[2099-01-01 00:00:00Z],
      capacity: capacity
    }

    {:ok, _} =
      TestCluster.call(peer, Horde.DynamicSupervisor, :start_child, [
        LevantarVuelo.DynamicSupervisor,
        {FlightServer, attrs}
      ])

    Process.sleep(1_000)
    id
  end

  # Reintenta `fun` cada 100 ms hasta que devuelva algo truthy (o 10 s)
  defp eventually(fun, tries \\ 100) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      _ when tries > 0 ->
        Process.sleep(100)
        eventually(fun, tries - 1)

      other ->
        flunk("no se cumplió a tiempo, último resultado: #{inspect(other)}")
    end
  end
end
