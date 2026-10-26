defmodule LevantarVuelo.SafeCallTest do
  use ExUnit.Case, async: true

  alias LevantarVuelo.SafeCall

  # GenServer mínimo para provocar cada tipo de falla
  defmodule Lento do
    use GenServer

    def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:ping, _from, state), do: {:reply, :pong, state}

    def handle_call(:dormir, _from, state) do
      Process.sleep(200)
      {:reply, :ok, state}
    end

    def handle_call(:parar, _from, state), do: {:stop, :normal, state}
  end

  test "si el proceso contesta, devuelve la respuesta tal cual" do
    pid = start_supervised!({Lento, nil})
    assert SafeCall.call(pid, :ping) == :pong
  end

  test "si no hay proceso con ese nombre devuelve :noproc" do
    assert SafeCall.call(:no_existe, :ping) == {:error, :noproc}
  end

  test "si se termina mientras esperamos la respuesta devuelve :down" do
    pid = start_supervised!({Lento, nil}, restart: :temporary)
    assert SafeCall.call(pid, :parar) == {:error, :down}
  end

  test "si no contesta a tiempo devuelve :timeout" do
    pid = start_supervised!({Lento, nil})
    assert SafeCall.call(pid, :dormir, 50) == {:error, :timeout}
  end

  test "run/1 atrapa el exit de un call hecho dentro de otra función" do
    assert SafeCall.run(fn -> GenServer.call(:no_existe, :ping) end) == {:error, :noproc}
  end
end
