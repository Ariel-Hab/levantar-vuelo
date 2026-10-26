defmodule LevantarVuelo.FlightTest do
  use ExUnit.Case, async: true
  alias LevantarVuelo.Flight

  # Vuelo base para los tests: 1 ventana, 1 pasillo, 0 medios
  defp vuelo_base do
    Flight.new(%{
      id: "fl_test",
      airline: "Aerolineas Test",
      origin: "EZE",
      destination: "MAD",
      departs_at: ~U[2026-12-20 22:00:00Z],
      offer_ends_at: ~U[2026-11-01 18:00:00Z],
      capacity: %{window: 1, aisle: 1, middle: 0}
    })
  end

  describe "reserve/3" do
    test "agrega una reserva pendiente" do
      flight = vuelo_base()
      {:ok, "r1", nuevo} = Flight.reserve(flight, "usuario_1", "r1")
      assert nuevo.reservations["r1"].status == :pending
      assert nuevo.reservations["r1"].user_id == "usuario_1"
    end

    test "permite overbooking: se puede reservar aunque no haya asientos" do
      flight = vuelo_base()
      {:ok, _, f1} = Flight.reserve(flight, "u1", "r1")
      {:ok, _, f2} = Flight.reserve(f1, "u2", "r2")
      # ya no hay asientos disponibles pero igual deja reservar
      {:ok, _, f3} = Flight.reserve(f2, "u3", "r3")
      assert map_size(f3.reservations) == 3
    end

    test "rechaza reserva en vuelo cerrado" do
      {cerrado, _} = Flight.close(vuelo_base(), :expired)
      assert {:error, :flight_closed} = Flight.reserve(cerrado, "u1", "r1")
    end

    # Idempotencia: si el cliente reintenta (por ejemplo después de un timeout)
    # la reserva no tiene que volver a pending ni perder los asientos.
    test "reintentar con el mismo id no pisa la reserva (idempotente)" do
      flight = vuelo_base()
      {:ok, "r1", f1} = Flight.reserve(flight, "ana", "r1")
      {:ok, f2, [:window]} = Flight.assign_seats(f1, "r1", [:window])

      # El reintento devuelve lo mismo que la primera vez...
      assert {:ok, "r1", f3} = Flight.reserve(f2, "ana", "r1")

      # ...y no cambia nada: la ventanilla sigue siendo de ana
      assert f3 == f2
      assert f3.reservations["r1"].status == :confirmed
      assert f3.reservations["r1"].seats == [:window]
      assert f3.available.window == 0
    end

    test "otro usuario no puede usar un id de reserva que ya existe" do
      flight = vuelo_base()
      {:ok, "r1", f1} = Flight.reserve(flight, "ana", "r1")

      assert {:error, :reservation_id_taken} = Flight.reserve(f1, "beto", "r1")
    end
  end

  describe "escenario A/B/C del enunciado" do
    # Vuelo X: 1 ventana, 1 pasillo
    # A y B reservan. B elige ventana -> compra.
    # C reserva. A pide ventana -> 409. C pide :any -> recibe pasillo, compra.
    # Quedan 0 asientos: vuelo se cierra, A queda cancelada.

    test "escenario completo" do
      flight = vuelo_base()

      # A y B reservan (overbooking permitido)
      {:ok, "rA", f1} = Flight.reserve(flight, "A", "rA")
      {:ok, "rB", f2} = Flight.reserve(f1, "B", "rB")

      # B elige ventana -> compra
      {:ok, f3, [:window]} = Flight.assign_seats(f2, "rB", [:window])
      assert f3.reservations["rB"].status == :confirmed
      assert f3.available.window == 0
      assert f3.available.aisle == 1

      # C reserva (sigue permitido: hay overbooking)
      {:ok, "rC", f4} = Flight.reserve(f3, "C", "rC")

      # A pide ventana -> error, ya no hay
      assert {:error, :unavailable, disponibilidad} = Flight.assign_seats(f4, "rA", [:window])
      assert disponibilidad.window == 0

      # C pide cualquiera -> recibe el pasillo
      {:ok, f5, assigned} = Flight.assign_seats(f4, "rC", [:any])
      assert :aisle in assigned
      assert f5.reservations["rC"].status == :confirmed

      # Quedan 0 asientos: el vuelo se cerró automáticamente
      assert {:closed, :sold_out} = f5.status

      # La reserva de A quedó cancelada al cerrarse el vuelo
      assert f5.reservations["rA"].status == :cancelled
    end
  end

  describe "assign_seats/3" do
    test "asigna asientos específicos si hay stock" do
      flight = vuelo_base()
      {:ok, _, f1} = Flight.reserve(flight, "u1", "r1")
      {:ok, nuevo, assigned} = Flight.assign_seats(f1, "r1", [:window, :aisle])
      assert :window in assigned
      assert :aisle in assigned
      assert nuevo.available.window == 0
      assert nuevo.available.aisle == 0
    end

    test "todo o nada: si no alcanza un tipo no asigna nada" do
      flight = vuelo_base()
      {:ok, _, f1} = Flight.reserve(flight, "u1", "r1")
      # pide 2 ventanas pero solo hay 1
      assert {:error, :unavailable, _avail} = Flight.assign_seats(f1, "r1", [:window, :window])
    end

    test ":any usa primero los del medio, preservando ventanas y pasillos" do
      flight =
        Flight.new(%{
          id: "fl2",
          airline: "Test",
          origin: "EZE",
          destination: "BUE",
          departs_at: ~U[2026-12-20 22:00:00Z],
          offer_ends_at: ~U[2026-11-01 18:00:00Z],
          capacity: %{window: 2, aisle: 2, middle: 2}
        })

      {:ok, _, f1} = Flight.reserve(flight, "u1", "r1")
      {:ok, _nuevo, assigned} = Flight.assign_seats(f1, "r1", [:any])
      # debe asignar :middle primero
      assert assigned == [:middle]
    end

    test "cierra el vuelo cuando se agotan los asientos" do
      flight = vuelo_base()
      {:ok, _, f1} = Flight.reserve(flight, "u1", "r1")
      {:ok, cerrado, _} = Flight.assign_seats(f1, "r1", [:window, :aisle])
      assert {:closed, :sold_out} = cerrado.status
    end

    # Idempotencia: el cliente puede recibir un :timeout con la compra ya hecha
    test "repetir el mismo pedido devuelve los mismos asientos sin cambiar nada" do
      {:ok, _, f1} = Flight.reserve(vuelo_base(), "u1", "r1")
      {:ok, f2, asientos} = Flight.assign_seats(f1, "r1", [:window])

      assert {:ok, ^f2, ^asientos} = Flight.assign_seats(f2, "r1", [:window])
    end

    test "el reintento funciona aunque esa compra haya agotado el vuelo" do
      {:ok, _, f1} = Flight.reserve(vuelo_base(), "u1", "r1")
      {:ok, cerrado, asientos} = Flight.assign_seats(f1, "r1", [:window, :aisle])

      # el orden de los asientos pedidos no importa
      assert {:ok, ^cerrado, ^asientos} = Flight.assign_seats(cerrado, "r1", [:aisle, :window])
    end

    test "otro pedido sobre una reserva ya confirmada da error" do
      {:ok, _, f1} = Flight.reserve(vuelo_base(), "u1", "r1")
      {:ok, f2, _} = Flight.assign_seats(f1, "r1", [:window])

      assert {:error, {:reservation_already, :confirmed}} = Flight.assign_seats(f2, "r1", [:aisle])
    end
  end

  describe "close/2" do
    test "cancela reservas pendientes y conserva las confirmadas" do
      flight = vuelo_base()
      {:ok, _, f1} = Flight.reserve(flight, "u1", "r1")
      {:ok, _, f2} = Flight.reserve(f1, "u2", "r2")
      {:ok, f3, _} = Flight.assign_seats(f2, "r1", [:window])

      {cerrado, cancelados} = Flight.close(f3, :expired)

      assert cerrado.reservations["r1"].status == :confirmed
      assert cerrado.reservations["r2"].status == :cancelled
      assert "u2" in cancelados
      assert {:closed, :expired} = cerrado.status
    end
  end
end
