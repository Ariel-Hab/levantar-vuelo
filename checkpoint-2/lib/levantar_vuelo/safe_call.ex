defmodule LevantarVuelo.SafeCall do
  @moduledoc """
  GenServer.call que no tira abajo al proceso que llama.

  Cuando el destino no existe, se muere durante la llamada, vive en un nodo
  que se desconectó o no contesta a tiempo, GenServer.call hace `exit` en el
  proceso que llamó. Es un exit, no una excepción, por eso `rescue` no lo
  atrapa: hace falta `catch :exit`.

  Lo usan FlightServer y AlertIndex. Cada uno decide qué significa cada motivo
  (por ejemplo, para FlightServer `:noproc` quiere decir "el vuelo no existe").
  """

  @default_timeout 5_000

  @doc """
  Igual que GenServer.call/3, pero devuelve {:error, motivo} en vez de hacer exit:

    * `:noproc`   — no hay proceso con ese nombre
    * `:down`     — el proceso existía pero terminó mientras esperábamos la
                    respuesta (si tiene supervisor, en un momento vuelve)
    * `:nodedown` — el proceso vivía en un nodo que se desconectó
    * `:timeout`  — no contestó a tiempo (¡el pedido pudo haberse aplicado igual!)

  Si el proceso destino se cae por un bug mientras atiende el pedido, el exit
  NO se atrapa: let it crash, que lo vea el supervisor y el log.
  """
  def call(server, msg, timeout \\ @default_timeout) do
    GenServer.call(server, msg, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :noproc}
    :exit, {reason, _} when reason in [:normal, :shutdown, :killed] -> {:error, :down}
    :exit, {{:shutdown, _}, _} -> {:error, :down}
    :exit, {{:nodedown, _node}, _} -> {:error, :nodedown}
    :exit, {:timeout, _} -> {:error, :timeout}
  end
end
