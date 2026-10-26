defmodule LevantarVuelo.TestCluster do
  @moduledoc """
  Levanta un cluster de verdad para los tests multi-nodo, con `:peer` (OTP 25+).

  Cada peer es otra VM de Erlang en esta máquina con la aplicación entera:
  Horde, réplicas, alertas y avisos, con la config de producción (factor 3,
  quórums de 2). El test maneja cada peer por su entrada/salida estándar
  (`connection: :standard_io`), no por distribución: así el nodo que corre los
  tests no se suma al cluster ni a Horde.
  """

  @doc "Levanta `count` nodos conectados entre sí. Devuelve [{peer, nodo}]."
  def start(count) do
    suffix = System.unique_integer([:positive])
    peers = for i <- 1..count, do: start_peer(:"lv#{i}_#{suffix}")
    nodes = Enum.map(peers, fn {_peer, node} -> node end)

    # Primero la aplicación y después la conexión, como en Docker con libcluster.
    # Al revés, Horde ve nodos donde su supervisor todavía no existe, el monitor
    # que les pone muere en el acto y, cuando el nodo se cae de verdad, nadie lo
    # marca como muerto: sus vuelos no se reinician en otro lado.
    for {peer, _} <- peers, do: start_app(peer)
    for {peer, _} <- peers, node <- nodes, do: call(peer, Node, :connect, [node])

    peers
  end

  @doc "Ejecuta `module.function(args)` dentro del peer."
  def call(peer, module, function, args, timeout \\ 15_000) do
    :peer.call(peer, module, function, args, timeout)
  end

  @doc "Apaga el peer de golpe, como si se cayera el nodo. Si ya estaba apagado, no hace nada."
  def stop(peer) do
    :peer.stop(peer)
  catch
    :exit, _already_stopped -> :ok
  end

  defp start_peer(name) do
    {:ok, peer, node} =
      :peer.start(%{
        name: name,
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        # logger_level: sin los avisos de arranque de la VM (en Windows, uno por
        # cada línea rara del archivo hosts)
        args: [~c"-setcookie", ~c"levantar_test", ~c"-kernel", ~c"logger_level", ~c"warning" | code_paths()]
      })

    {peer, node}
  end

  # El peer usa el mismo código compilado que este nodo (deps incluidas)
  defp code_paths, do: Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

  defp start_app(peer) do
    env = [
      replication: [factor: 3, write_quorum: 2, read_quorum: 2, timeout: 1_000],
      cluster_topologies: [],
      flight_max_mailbox: 1_000
    ]

    for {key, value} <- env, do: call(peer, Application, :put_env, [:levantar_vuelo, key, value])
    call(peer, Application, :put_env, [:logger, :level, :warning])
    # Puerto 0: Bandit elige uno libre (todos los peers corren en la misma máquina)
    call(peer, System, :put_env, ["PORT", "0"])
    {:ok, _} = call(peer, Application, :ensure_all_started, [:levantar_vuelo])
  end

  defmodule Listener do
    @moduledoc """
    Corre dentro de un peer: se suscribe a los avisos de un usuario y los
    guarda, para que el test los consulte después con `received/1`.
    """

    def start(user_id) do
      parent = self()

      pid =
        spawn(fn ->
          LevantarVuelo.Notifier.subscribe(user_id)
          send(parent, :subscribed)
          loop([])
        end)

      receive do
        :subscribed -> Process.register(pid, name(user_id))
      end

      :ok
    end

    def received(user_id) do
      send(name(user_id), {:get, self()})

      receive do
        {:events, events} -> events
      end
    end

    defp loop(events) do
      receive do
        {:notification, event} -> loop([event | events])
        {:get, from} ->
          send(from, {:events, Enum.reverse(events)})
          loop(events)
      end
    end

    defp name(user_id), do: :"listener_#{user_id}"
  end
end
