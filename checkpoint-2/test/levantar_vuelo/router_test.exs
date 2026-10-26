defmodule LevantarVuelo.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias LevantarVuelo.Router

  @opts Router.init([])

  @vuelo %{
    id: "fl_router_post",
    airline: "Aerolineas Test",
    origin: "EZE",
    destination: "MAD",
    departs_at: "2026-12-20T22:00:00Z",
    offer_ends_at: "2099-01-01T00:00:00Z",
    capacity: %{window: 2, aisle: 2, middle: 1}
  }

  test "POST /flights crea el vuelo bajo el DynamicSupervisor y repetirlo da 409" do
    conn = conn(:post, "/flights", @vuelo) |> Router.call(@opts)
    assert conn.status == 201

    [{pid, _}] = Horde.Registry.lookup(LevantarVuelo.Registry, "fl_router_post")
    assert {:undefined, ^pid, :worker, _} =
             Horde.DynamicSupervisor.which_children(LevantarVuelo.DynamicSupervisor)
             |> List.keyfind(pid, 1)

    conn = conn(:post, "/flights", @vuelo) |> Router.call(@opts)
    assert conn.status == 409
  end

  # Antes de usar el wrapper estos pedidos daban 500: el exit de
  # GenServer.call tiraba abajo al proceso de la request.
  test "GET de un vuelo que no existe devuelve 404" do
    conn = conn(:get, "/flights/no-existe") |> Router.call(@opts)
    assert conn.status == 404
  end

  test "reservar en un vuelo que no existe devuelve 404" do
    conn =
      conn(:post, "/flights/no-existe/reservations", %{reservation_id: "r1", user_id: "u1"})
      |> Router.call(@opts)

    assert conn.status == 404
  end

  test "elegir asientos en un vuelo que no existe devuelve 404 (no 422)" do
    conn =
      conn(:post, "/flights/no-existe/reservations/r1/seats", %{seats: ["window"]})
      |> Router.call(@opts)

    assert conn.status == 404
  end
end
