defmodule LevantarVuelo.FlightServerTest do
  use ExUnit.Case, async: false

  alias LevantarVuelo.{FlightServer, Notifier, ReplicaStore}

  # Atributos base para arrancar un FlightServer en los tests
  defp vuelo_attrs(id) do
    %{
      id: id,
      airline: "Aerolineas Test",
      origin: "EZE",
      destination: "MAD",
      departs_at: ~U[2026-12-20 22:00:00Z],
      offer_ends_at: ~U[2099-01-01 00:00:00Z],
      capacity: %{window: 1, aisle: 1, middle: 0}
    }
  end

  # setup corre antes de cada test. Usamos un ID único por test para que
  # los tests no choquen entre sí en el Registry (que ya arrancó la Application).
  setup context do
    id = "fl_#{context.test |> to_string() |> :erlang.phash2()}"
    start_supervised!({FlightServer, vuelo_attrs(id)})
    {:ok, flight_id: id}
  end

  test "get devuelve el estado del vuelo", %{flight_id: id} do
    {:ok, flight} = FlightServer.get(id)
    assert flight.id == id
    assert flight.status == :open
    assert flight.available == %{window: 1, aisle: 1, middle: 0}
  end

  # Antes GenServer.call hacía exit (:noproc) y tiraba abajo al que llamaba
  test "las operaciones sobre un vuelo que no existe devuelven :not_found" do
    assert {:error, :not_found} = FlightServer.get("no-existe")
    assert {:error, :not_found} = FlightServer.reserve("no-existe", "u1", "r1")
    assert {:error, :not_found} = FlightServer.assign_seats("no-existe", "r1", [:window])
  end

  test "reserve agrega una reserva pendiente", %{flight_id: id} do
    {:ok, "r1"} = FlightServer.reserve(id, "usuario_1", "r1")
    {:ok, flight} = FlightServer.get(id)
    assert flight.reservations["r1"].status == :pending
  end

  test "assign_seats confirma la reserva y descuenta stock", %{flight_id: id} do
    FlightServer.reserve(id, "u1", "r1")
    {:ok, assigned} = FlightServer.assign_seats(id, "r1", [:window])

    assert :window in assigned

    {:ok, flight} = FlightServer.get(id)
    assert flight.reservations["r1"].status == :confirmed
    assert flight.available.window == 0
  end

  test "assign_seats devuelve error si no hay disponibilidad", %{flight_id: id} do
    FlightServer.reserve(id, "u1", "r1")
    FlightServer.reserve(id, "u2", "r2")

    FlightServer.assign_seats(id, "r1", [:window])

    assert {:error, :unavailable, disponibilidad} =
             FlightServer.assign_seats(id, "r2", [:window])

    assert disponibilidad.window == 0
  end

  test "escenario A/B/C completo a través del proceso", %{flight_id: id} do
    Notifier.subscribe("A")
    FlightServer.reserve(id, "A", "rA")
    FlightServer.reserve(id, "B", "rB")

    {:ok, _} = FlightServer.assign_seats(id, "rB", [:window])

    FlightServer.reserve(id, "C", "rC")

    assert {:error, :unavailable, _} = FlightServer.assign_seats(id, "rA", [:window])

    {:ok, assigned} = FlightServer.assign_seats(id, "rC", [:any])
    assert :aisle in assigned

    {:ok, flight} = FlightServer.get(id)
    assert {:closed, :sold_out} = flight.status
    assert flight.reservations["rA"].status == :cancelled

    # A tenía una reserva: se entera de que el vuelo se agotó
    assert_receive {:notification, {:flight_closed, ^id, :sold_out}}
  end

  test "el vuelo se cierra cuando vence el tiempo de oferta" do
    Notifier.subscribe("u1")

    start_supervised!(
      {FlightServer,
       %{vuelo_attrs("fl_expira") | offer_ends_at: DateTime.add(DateTime.utc_now(), 50, :millisecond)}},
      id: :fl_expira
    )

    FlightServer.reserve("fl_expira", "u1", "r1")
    Process.sleep(150)

    {:ok, flight} = FlightServer.get("fl_expira")
    assert {:closed, :expired} = flight.status
    assert flight.reservations["r1"].status == :cancelled
    assert_receive {:notification, {:flight_closed, "fl_expira", :expired}}
  end

  describe "réplica" do
    test "si el proceso se cae, al reiniciarse recupera el estado y sube la época", %{flight_id: id} do
      {:ok, "r1"} = FlightServer.reserve(id, "u1", "r1")
      {:ok, _} = FlightServer.assign_seats(id, "r1", [:window])

      pid = whereis(id)
      assert :sys.get_state(pid).epoch == 1

      # El supervisor de ExUnit lo reinicia, igual que haría Horde
      Process.exit(pid, :kill)
      new_pid = wait_restart(id, pid)

      {:ok, flight} = FlightServer.get(id)
      assert flight.reservations["r1"].status == :confirmed
      assert flight.available.window == 0
      assert :sys.get_state(new_pid).epoch == 2
    end

    test "un primario viejo no confirma nada y se retira (fencing)" do
      id = "fl_fencing"
      start_supervised!({FlightServer, vuelo_attrs(id)}, id: :fl_fencing, restart: :transient)
      pid = whereis(id)
      ref = Process.monitor(pid)

      # El reclamo del vuelo corre en handle_continue, después de init. Un pedido
      # cualquiera espera a que termine.
      {:ok, _} = FlightServer.get(id)

      # Otro primario (época 2) reclama el vuelo, como pasaría después de una partición
      {:ok, {{1, version}, flight}} = ReplicaStore.fetch_latest([node()], id)
      {:ok, _} = ReplicaStore.replicate([node()], id, {2, version}, flight)

      assert FlightServer.reserve(id, "u1", "r1") == {:error, :stale_epoch}
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :stale_epoch}}

      {:ok, {{2, ^version}, flight}} = ReplicaStore.fetch_latest([node()], id)
      assert flight.reservations == %{}
    end
  end

  describe "límite de mailbox" do
    setup do
      previous = Application.get_env(:levantar_vuelo, :flight_max_mailbox)
      Application.put_env(:levantar_vuelo, :flight_max_mailbox, 5)
      on_exit(fn -> Application.put_env(:levantar_vuelo, :flight_max_mailbox, previous) end)
    end

    test "con el mailbox saturado contesta :overloaded enseguida", %{flight_id: id} do
      {:ok, _} = FlightServer.get(id)
      pid = whereis(id)

      # Lo frenamos para que los pedidos se acumulen en el mailbox
      :sys.suspend(pid)
      tasks = for _ <- 1..20, do: Task.async(fn -> FlightServer.get(id) end)
      wait_until(fn -> Process.info(pid, :message_queue_len) == {:message_queue_len, 20} end)
      :sys.resume(pid)

      results = Task.await_many(tasks)
      # Los primeros encuentran la cola llena y se rechazan; los últimos se atienden
      assert Enum.count(results, &match?({:error, :overloaded}, &1)) > 0
      assert Enum.count(results, &match?({:ok, _}, &1)) > 0
    end
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries > 0 -> Process.sleep(10); wait_until(fun, tries - 1)
    end
  end

  defp whereis(id) do
    [{pid, _}] = Horde.Registry.lookup(LevantarVuelo.Registry, id)
    pid
  end

  # Espera a que el vuelo tenga un proceso distinto de old_pid
  defp wait_restart(id, old_pid, tries \\ 100) do
    case Horde.Registry.lookup(LevantarVuelo.Registry, id) do
      [{pid, _}] when pid != old_pid ->
        pid

      _ when tries > 0 ->
        Process.sleep(10)
        wait_restart(id, old_pid, tries - 1)
    end
  end
end
