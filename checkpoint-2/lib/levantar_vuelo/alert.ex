defmodule LevantarVuelo.Alert do
  @moduledoc """
  Módulo puro de dominio de alertas. Solo datos y lógica de matching.
  """

  defstruct [:id, :user_id, :origin, :destination, :date, :month]

  @doc """
  Crea una alerta nueva. date y month son opcionales (puede venir uno, los dos o ninguno).
  - date:  %Date{} para un día puntual
  - month: {año, mes} para un mes entero, ej: {2026, 12}
  """
  def new(attrs), do: struct!(__MODULE__, attrs)

  @doc """
  Devuelve true si esta alerta aplica al vuelo dado.
  Condiciones: mismo origen, mismo destino, y si tiene fecha/mes que coincida.
  """
  def matches?(%__MODULE__{} = alert, flight) do
    origin_match?(alert, flight) and
      destination_match?(alert, flight) and
      date_match?(alert, flight)
  end

  defp origin_match?(alert, flight), do: alert.origin == flight.origin
  defp destination_match?(alert, flight), do: alert.destination == flight.destination

  # Si la alerta no tiene ni fecha ni mes, coincide con cualquier vuelo
  defp date_match?(%{date: nil, month: nil}, _flight), do: true

  # Si tiene fecha puntual, el vuelo tiene que salir ese día
  defp date_match?(%{date: date, month: nil}, flight) when not is_nil(date) do
    DateTime.to_date(flight.departs_at) == date
  end

  # Si tiene mes, el vuelo tiene que salir en ese año/mes
  defp date_match?(%{date: nil, month: {year, month}}, flight) do
    flight.departs_at.year == year and flight.departs_at.month == month
  end

  # Si tiene los dos, tienen que coincidir ambos
  defp date_match?(%{date: date, month: {year, month}}, flight) do
    DateTime.to_date(flight.departs_at) == date and
      flight.departs_at.year == year and
      flight.departs_at.month == month
  end
end
