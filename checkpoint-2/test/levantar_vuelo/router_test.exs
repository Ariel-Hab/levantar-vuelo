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

  # Antes un body incompleto rompía un pattern match y la respuesta era 500
  test "un body inválido devuelve 400 con un mensaje" do
    conn = conn(:post, "/flights", Map.delete(@vuelo, :airline)) |> Router.call(@opts)
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] =~ "airline"

    conn = conn(:post, "/alerts", %{id: "a1"}) |> Router.call(@opts)
    assert conn.status == 400

    conn = conn(:post, "/flights/fl_x/reservations", %{user_id: "u1"}) |> Router.call(@opts)
    assert conn.status == 400
  end

  # Antes se hacía String.to_atom con lo que mandara el cliente
  test "un asiento desconocido devuelve 400 y no crea un átomo" do
    conn =
      conn(:post, "/flights/fl_x/reservations/r1/seats", %{seats: ["asiento_inventado_xyz"]})
      |> Router.call(@opts)

    assert conn.status == 400
    assert_raise ArgumentError, fn -> String.to_existing_atom("asiento_inventado_xyz") end
  end

  test "POST /flights avisa a los usuarios con una alerta que coincide (F3)" do
    LevantarVuelo.AlertIndex.add(
      LevantarVuelo.Alert.new(%{id: "a_router", user_id: "u_router", origin: "EZE",
                                destination: "MAD", date: nil, month: nil})
    )

    LevantarVuelo.Notifier.subscribe("u_router")
    conn = conn(:post, "/flights", %{@vuelo | id: "fl_router_alerta"}) |> Router.call(@opts)

    assert Jason.decode!(conn.resp_body)["notified_users"] >= 1
    assert_receive {:notification, {:flight_published, "fl_router_alerta"}}
  end

  test "GET /flights/:id/location dice en qué nodo vive el vuelo" do
    conn(:post, "/flights", %{@vuelo | id: "fl_router_location"}) |> Router.call(@opts)

    conn = conn(:get, "/flights/fl_router_location/location") |> Router.call(@opts)
    assert conn.status == 200

    body = Jason.decode!(conn.resp_body)
    assert body["node"] == to_string(node())
    assert body["epoch"] == 1
    assert body["recovering"] == false
    # Fuera de Docker el nombre del nodo no tiene IP: no hay contenedor
    assert body["container"] == nil
  end

  test "GET /flights/:id/location de un vuelo que no existe devuelve 404" do
    conn = conn(:get, "/flights/no-existe/location") |> Router.call(@opts)
    assert conn.status == 404
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
