defmodule LevantarVuelo.ParamsTest do
  use ExUnit.Case, async: true

  alias LevantarVuelo.Params

  @vuelo %{
    "id" => "fl_1",
    "airline" => "AR",
    "origin" => "EZE",
    "destination" => "MAD",
    "departs_at" => "2026-12-20T22:00:00Z",
    "offer_ends_at" => "2026-12-01T00:00:00Z",
    "capacity" => %{"window" => 2, "aisle" => 2, "middle" => 1}
  }

  describe "flight/1" do
    test "convierte un body válido" do
      assert {:ok, attrs} = Params.flight(@vuelo)
      assert attrs.departs_at == ~U[2026-12-20 22:00:00Z]
      assert attrs.capacity == %{window: 2, aisle: 2, middle: 1}
    end

    test "rechaza campos faltantes, fechas inválidas y capacidades negativas" do
      assert {:error, _} = Params.flight(Map.delete(@vuelo, "airline"))
      assert {:error, "departs_at" <> _} = Params.flight(%{@vuelo | "departs_at" => "mañana"})
      assert {:error, _} = Params.flight(put_in(@vuelo, ["capacity", "window"], -1))
      assert {:error, _} = Params.flight(%{@vuelo | "id" => 123})
    end
  end

  describe "alert/1" do
    test "date y month son opcionales" do
      base = %{"id" => "a1", "user_id" => "u1", "origin" => "EZE", "destination" => "MAD"}

      assert {:ok, %{date: nil, month: nil}} = Params.alert(base)
      assert {:ok, %{date: ~D[2026-12-20]}} = Params.alert(Map.put(base, "date", "2026-12-20"))
      assert {:ok, %{month: {2026, 12}}} = Params.alert(Map.put(base, "month", %{"year" => 2026, "month" => 12}))
      assert {:error, _} = Params.alert(Map.put(base, "month", %{"year" => 2026, "month" => 13}))
    end
  end

  describe "seats/1" do
    test "solo acepta los tipos de asiento conocidos" do
      assert Params.seats(%{"seats" => ["window", "any"]}) == {:ok, [:window, :any]}
      assert {:error, _} = Params.seats(%{"seats" => ["ventana"]})
      assert {:error, _} = Params.seats(%{"seats" => []})
      assert {:error, _} = Params.seats(%{})
    end
  end
end
