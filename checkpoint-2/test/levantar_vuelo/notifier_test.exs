defmodule LevantarVuelo.NotifierTest do
  use ExUnit.Case, async: true

  alias LevantarVuelo.{Notifier, SSE}

  test "el suscripto recibe el aviso y los demás usuarios no" do
    Notifier.subscribe("u_notifier_1")

    Notifier.notify(["u_notifier_1"], {:flight_published, "fl_1"})
    Notifier.notify(["u_notifier_2"], {:flight_published, "fl_2"})

    assert_receive {:notification, {:flight_published, "fl_1"}}
    refute_receive {:notification, {:flight_published, "fl_2"}}
  end

  test "SSE.encode arma un evento por aviso, con los datos en JSON" do
    assert decode(SSE.encode({:flight_published, "fl_1"})) ==
             {"flight_published", %{"flight_id" => "fl_1"}}

    assert decode(SSE.encode({:flight_closed, "fl_1", :sold_out})) ==
             {"flight_closed", %{"flight_id" => "fl_1", "reason" => "sold_out"}}
  end

  # "event: X\ndata: {json}\n\n" → {X, json decodificado}. Cada evento termina
  # con una línea en blanco.
  defp decode(text) do
    assert String.ends_with?(text, "\n\n")
    ["event: " <> name, "data: " <> data] = text |> String.trim_trailing() |> String.split("\n")
    {name, Jason.decode!(data)}
  end
end
