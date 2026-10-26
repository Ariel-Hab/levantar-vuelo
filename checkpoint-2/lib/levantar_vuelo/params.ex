defmodule LevantarVuelo.Params do
  @moduledoc """
  Valida y convierte el body de los pedidos HTTP. Cada función devuelve
  `{:ok, datos}` o `{:error, mensaje}`, y el Router contesta el mensaje con 400.

  Antes, un body incompleto hacía fallar un pattern match en el Router y la
  respuesta era 500. Y los asientos se convertían con `String.to_atom/1`: cada
  texto distinto que mandara un cliente creaba un átomo nuevo, y los átomos
  nunca se liberan (con suficientes pedidos, se cae la VM).
  """

  # Lista blanca de asientos: solo estos textos se convierten en átomos
  @seat_types %{"window" => :window, "aisle" => :aisle, "middle" => :middle, "any" => :any}

  defguardp text(value) when is_binary(value) and byte_size(value) > 0
  defguardp count(value) when is_integer(value) and value >= 0

  @doc "POST /flights"
  def flight(%{
        "id" => id,
        "airline" => airline,
        "origin" => origin,
        "destination" => destination,
        "departs_at" => departs_at,
        "offer_ends_at" => offer_ends_at,
        "capacity" => %{"window" => window, "aisle" => aisle, "middle" => middle}
      })
      when text(id) and text(airline) and text(origin) and text(destination) and
             count(window) and count(aisle) and count(middle) do
    with {:ok, departs_at} <- datetime(departs_at, "departs_at"),
         {:ok, offer_ends_at} <- datetime(offer_ends_at, "offer_ends_at") do
      {:ok,
       %{
         id: id,
         airline: airline,
         origin: origin,
         destination: destination,
         departs_at: departs_at,
         offer_ends_at: offer_ends_at,
         capacity: %{window: window, aisle: aisle, middle: middle}
       }}
    end
  end

  def flight(_body) do
    {:error,
     "se esperan id, airline, origin y destination (texto), departs_at y offer_ends_at " <>
       "(fecha ISO 8601) y capacity con window, aisle y middle (enteros >= 0)"}
  end

  @doc "POST /alerts. `date` (\"2026-12-20\") y `month` (%{year, month}) son opcionales."
  def alert(%{"id" => id, "user_id" => user_id, "origin" => origin, "destination" => destination} = body)
      when text(id) and text(user_id) and text(origin) and text(destination) do
    with {:ok, date} <- optional_date(body["date"]),
         {:ok, month} <- optional_month(body["month"]) do
      {:ok,
       %{id: id, user_id: user_id, origin: origin, destination: destination, date: date, month: month}}
    end
  end

  def alert(_body) do
    {:error, "se esperan id, user_id, origin y destination (texto); date y month son opcionales"}
  end

  @doc "POST /flights/:id/reservations"
  def reservation(%{"reservation_id" => reservation_id, "user_id" => user_id})
      when text(reservation_id) and text(user_id),
      do: {:ok, reservation_id, user_id}

  def reservation(_body), do: {:error, "se esperan reservation_id y user_id (texto)"}

  @doc "POST /flights/:id/reservations/:rid/seats"
  def seats(%{"seats" => [_ | _] = seats}) do
    if Enum.all?(seats, &Map.has_key?(@seat_types, &1)) do
      {:ok, Enum.map(seats, &Map.fetch!(@seat_types, &1))}
    else
      {:error, "cada asiento tiene que ser window, aisle, middle o any"}
    end
  end

  def seats(_body), do: {:error, "se espera seats: una lista no vacía de window, aisle, middle o any"}

  # ---------------------------------------------------------------------------

  defp datetime(value, field) do
    with true <- is_binary(value),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(value) do
      {:ok, datetime}
    else
      _ -> {:error, "#{field}: fecha inválida, usar ISO 8601 (ej. 2026-12-20T22:00:00Z)"}
    end
  end

  defp optional_date(nil), do: {:ok, nil}

  defp optional_date(value) do
    with true <- is_binary(value),
         {:ok, date} <- Date.from_iso8601(value) do
      {:ok, date}
    else
      _ -> {:error, "date: fecha inválida, usar ISO 8601 (ej. 2026-12-20)"}
    end
  end

  defp optional_month(nil), do: {:ok, nil}

  defp optional_month(%{"year" => year, "month" => month})
       when is_integer(year) and month in 1..12,
       do: {:ok, {year, month}}

  defp optional_month(_value), do: {:error, "month: se espera %{\"year\": 2026, \"month\": 12}"}
end
