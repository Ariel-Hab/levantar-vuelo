defmodule LevantarVuelo.AlertTest do
  use ExUnit.Case, async: true

  alias LevantarVuelo.Alert

  # Vuelo base para testear el matching
  defp vuelo do
    %{
      origin: "EZE",
      destination: "MAD",
      departs_at: ~U[2026-12-15 10:00:00Z]
    }
  end

  describe "matches?/2" do
    test "coincide si origen y destino son iguales y no hay filtro de fecha" do
      alert = Alert.new(%{id: "a1", user_id: "u1", origin: "EZE", destination: "MAD", date: nil, month: nil})
      assert Alert.matches?(alert, vuelo())
    end

    test "no coincide si el origen es distinto" do
      alert = Alert.new(%{id: "a1", user_id: "u1", origin: "AEP", destination: "MAD", date: nil, month: nil})
      refute Alert.matches?(alert, vuelo())
    end

    test "no coincide si el destino es distinto" do
      alert = Alert.new(%{id: "a1", user_id: "u1", origin: "EZE", destination: "BCN", date: nil, month: nil})
      refute Alert.matches?(alert, vuelo())
    end

    test "coincide si la fecha puntual es la misma" do
      alert = Alert.new(%{id: "a1", user_id: "u1", origin: "EZE", destination: "MAD",
                          date: ~D[2026-12-15], month: nil})
      assert Alert.matches?(alert, vuelo())
    end

    test "no coincide si la fecha puntual es distinta" do
      alert = Alert.new(%{id: "a1", user_id: "u1", origin: "EZE", destination: "MAD",
                          date: ~D[2026-12-20], month: nil})
      refute Alert.matches?(alert, vuelo())
    end

    test "coincide si el mes coincide" do
      alert = Alert.new(%{id: "a1", user_id: "u1", origin: "EZE", destination: "MAD",
                          date: nil, month: {2026, 12}})
      assert Alert.matches?(alert, vuelo())
    end

    test "no coincide si el mes es distinto" do
      alert = Alert.new(%{id: "a1", user_id: "u1", origin: "EZE", destination: "MAD",
                          date: nil, month: {2026, 11}})
      refute Alert.matches?(alert, vuelo())
    end
  end
end

defmodule LevantarVuelo.AlertIndexTest do
  use ExUnit.Case, async: false

  alias LevantarVuelo.{Alert, AlertIndex}

  # El AlertIndex ya está corriendo (lo levantó la Application).
  # Antes de cada test lo vaciamos para que no haya alertas de otros tests.
  setup do
    # Borramos todas las alertas existentes pidiendo el estado interno
    alerts = :sys.get_state(AlertIndex)
    Enum.each(alerts, fn {id, _} -> AlertIndex.remove(id) end)
    :ok
  end

  test "add y matching_users devuelve los usuarios que coinciden" do
    AlertIndex.add(Alert.new(%{id: "a1", user_id: "u1", origin: "EZE", destination: "MAD", date: nil, month: nil}))
    AlertIndex.add(Alert.new(%{id: "a2", user_id: "u2", origin: "EZE", destination: "MAD", date: nil, month: nil}))
    AlertIndex.add(Alert.new(%{id: "a3", user_id: "u3", origin: "AEP", destination: "MAD", date: nil, month: nil}))

    vuelo = %{origin: "EZE", destination: "MAD", departs_at: ~U[2026-12-15 10:00:00Z]}
    {:ok, users} = AlertIndex.matching_users(vuelo)

    assert "u1" in users
    assert "u2" in users
    refute "u3" in users
  end

  test "remove elimina la alerta y ya no aparece en matching" do
    AlertIndex.add(Alert.new(%{id: "a1", user_id: "u1", origin: "EZE", destination: "MAD", date: nil, month: nil}))
    AlertIndex.remove("a1")

    vuelo = %{origin: "EZE", destination: "MAD", departs_at: ~U[2026-12-15 10:00:00Z]}
    assert AlertIndex.matching_users(vuelo) == {:ok, []}
  end

  test "si el mismo usuario tiene dos alertas que coinciden aparece una sola vez" do
    AlertIndex.add(Alert.new(%{id: "a1", user_id: "u1", origin: "EZE", destination: "MAD", date: nil, month: nil}))
    AlertIndex.add(Alert.new(%{id: "a2", user_id: "u1", origin: "EZE", destination: "MAD", date: nil, month: {2026, 12}}))

    vuelo = %{origin: "EZE", destination: "MAD", departs_at: ~U[2026-12-15 10:00:00Z]}
    {:ok, users} = AlertIndex.matching_users(vuelo)

    assert users == ["u1"]
  end
end
