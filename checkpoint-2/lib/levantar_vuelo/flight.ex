defmodule LevantarVuelo.Flight do
  @moduledoc """
  Módulo puro de dominio del vuelo. No usa procesos ni OTP.
  Cada función recibe un estado y devuelve uno nuevo (estilo funcional).
  """

  # La estructura que representa el estado de un vuelo.
  # defstruct define los campos y sus valores por defecto.
  defstruct [
    :id,
    :airline,
    :origin,
    :destination,
    :departs_at,
    :offer_ends_at,
    capacity: %{window: 0, aisle: 0, middle: 0},
    available: %{window: 0, aisle: 0, middle: 0},
    reservations: %{},
    status: :open
  ]

  @type seat_type :: :window | :aisle | :middle | :any
  @type status :: :open | {:closed, :sold_out | :expired}

  # --- Creación ---

  @doc "Crea un vuelo nuevo a partir de los atributos iniciales."
  def new(attrs) do
    capacity = attrs.capacity
    struct!(__MODULE__, Map.put(attrs, :available, capacity))
  end

  # --- Reservar (F4) ---

  @doc """
  Agrega una reserva pendiente al vuelo. Overbooking permitido:
  se puede reservar aunque no queden asientos disponibles. Es idempotente
  Devuelve {:ok, reservation_id, nuevo_estado} o {:error, :flight_closed}.
  """
  def reserve(%__MODULE__{status: {:closed, _}}, _user_id, _reservation_id),
    do: {:error, :flight_closed}

  def reserve(%__MODULE__{} = flight, user_id, reservation_id) do
    case Map.get(flight.reservations, reservation_id) do
      nil ->
        reservation = %{user_id: user_id, status: :pending, seats: [], requested: nil}
        {:ok, reservation_id, put_in(flight.reservations[reservation_id], reservation)}

      %{user_id: ^user_id} ->
        {:ok, reservation_id, flight}            # reintento: no cambia nada

      _ ->
        {:error, :reservation_id_taken}          # ese id es de otro usuario
    end
  end

  # --- Elegir asientos (F5) ---

  @doc """
  Intenta asignar los asientos pedidos a una reserva. Es todo o nada:
  si no alcanza algún tipo, no asigna nada y devuelve el error con
  la disponibilidad actual para que el usuario elija de nuevo.

  seats_wanted es una lista de :window | :aisle | :middle | :any
  Ejemplo: [:window, :window, :aisle]

  Es idempotente: repetir el mismo pedido sobre una reserva ya confirmada
  devuelve los mismos asientos sin cambiar nada (sirve cuando el cliente
  recibió un :timeout y no sabe si se aplicó). Un pedido distinto da error.
  """
  def assign_seats(%__MODULE__{} = flight, rid, wanted) do
    reservation = Map.get(flight.reservations, rid)

    cond do
      # Va primero porque el vuelo pudo cerrarse justo con esa compra
      retry?(reservation, wanted) -> {:ok, flight, reservation.seats}
      match?({:closed, _}, flight.status) -> {:error, :flight_closed}
      is_nil(reservation) -> {:error, :reservation_not_found}
      reservation.status == :pending -> do_assign(flight, rid, wanted)
      true -> {:error, {:reservation_already, reservation.status}}
    end
  end

  # Mismo pedido sobre una reserva confirmada (el orden de los asientos no importa)
  defp retry?(%{status: :confirmed, requested: requested}, wanted), do: Enum.sort(wanted) == requested
  defp retry?(_reservation, _wanted), do: false

  defp do_assign(flight, rid, wanted) do
    # Separamos los pedidos específicos de los :any
    {specific, any_count} =
      Enum.reduce(wanted, {%{window: 0, aisle: 0, middle: 0}, 0}, fn
        :any, {acc, n} -> {acc, n + 1}
        type, {acc, n} -> {Map.update!(acc, type, &(&1 + 1)), n}
      end)

    case check_and_allocate(flight.available, specific, any_count) do
      {:ok, new_available, assigned} ->
        reservation = %{flight.reservations[rid] |
          status: :confirmed,
          seats: assigned,
          requested: Enum.sort(wanted)
        }
        new_state = %{flight |
          available: new_available,
          reservations: Map.put(flight.reservations, rid, reservation)
        }
        new_state = maybe_close_sold_out(new_state)
        {:ok, new_state, assigned}

      {:error, :unavailable} ->
        {:error, :unavailable, flight.available}
    end
  end

  # Verifica si hay stock y calcula la nueva disponibilidad + los asientos asignados.
  defp check_and_allocate(available, specific, any_count) do
    with {:ok, avail2, assigned_specific} <- deduct_specific(available, specific),
         {:ok, avail3, assigned_any} <- deduct_any(avail2, any_count) do
      {:ok, avail3, assigned_specific ++ assigned_any}
    end
  end

  defp deduct_specific(available, required) do
    Enum.reduce_while(required, {:ok, available, []}, fn
      {_type, 0}, acc ->
        {:cont, acc}

      {type, count}, {:ok, avail, assigned} ->
        current = Map.get(avail, type, 0)

        if current >= count do
          new_avail = Map.put(avail, type, current - count)
          new_assigned = assigned ++ List.duplicate(type, count)
          {:cont, {:ok, new_avail, new_assigned}}
        else
          {:halt, {:error, :unavailable}}
        end
    end)
  end

  # :any se asigna primero desde :middle (estrategia: preservar ventanas y pasillos)
  defp deduct_any(available, 0), do: {:ok, available, []}

  defp deduct_any(available, count) do
    order = [:middle, :aisle, :window]

    {final_avail, final_assigned, remaining} =
      Enum.reduce(order, {available, [], count}, fn type, {avail, assigned, left} ->
        stock = Map.get(avail, type, 0)
        take = min(stock, left)
        new_avail = Map.put(avail, type, stock - take)
        {new_avail, assigned ++ List.duplicate(type, take), left - take}
      end)

    if remaining == 0 do
      {:ok, final_avail, final_assigned}
    else
      {:error, :unavailable}
    end
  end

  # Si después de asignar todos los asientos disponibles llegan a 0, cierra el vuelo.
  defp maybe_close_sold_out(%__MODULE__{available: avail} = flight) do
    total = avail.window + avail.aisle + avail.middle

    if total == 0 do
      {closed_state, _cancelled_users} = close(flight, :sold_out)
      closed_state
    else
      flight
    end
  end

  # --- Cerrar vuelo (F6, F7, F8) ---

  @doc """
  Cierra el vuelo por la razón dada (:sold_out o :expired).
  Cancela todas las reservas pendientes y devuelve
  {nuevo_estado, usuarios_a_notificar}.
  """
  def close(%__MODULE__{} = flight, reason) do
    {new_reservations, cancelled_users} =
      Enum.reduce(flight.reservations, {%{}, []}, fn
        {_id, %{status: :confirmed}} = entry, {acc, users} ->
          {Map.put(acc, elem(entry, 0), elem(entry, 1)), users}

        {id, %{status: :pending, user_id: uid}}, {acc, users} ->
          cancelled = %{flight.reservations[id] | status: :cancelled}
          {Map.put(acc, id, cancelled), [uid | users]}
      end)

    new_state = %{flight | status: {:closed, reason}, reservations: new_reservations}
    {new_state, Enum.uniq(cancelled_users)}
  end
end
