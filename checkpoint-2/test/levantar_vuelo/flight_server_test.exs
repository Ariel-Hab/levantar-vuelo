defmodule LevantarVuelo.FlightServerTest do
  use ExUnit.Case, async: false

  alias LevantarVuelo.FlightServer

  # Atributos base para arrancar un FlightServer en los tests
  defp vuelo_attrs(id \\ "fl_test") do
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
  end

  test "el vuelo se cierra cuando vence el tiempo de oferta" do
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
  end
end
