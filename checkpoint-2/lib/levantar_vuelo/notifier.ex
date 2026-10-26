defmodule LevantarVuelo.Notifier do
  @moduledoc """
  Avisos a los usuarios: vuelo publicado que coincide con una alerta (F3) y
  vuelo cerrado por agotado o por fin de la oferta.

  Cada usuario tiene un topic `"user:<id>"` en Phoenix.PubSub. Quien quiere
  recibir sus avisos (la conexión SSE de `GET /users/:id/events`) se suscribe,
  y quien avisa hace broadcast. Phoenix.PubSub entrega el mensaje a los
  suscriptores de todos los nodos del cluster: el usuario puede estar
  conectado a un nodo y el vuelo vivir en otro.

  Es best-effort (AP): si el usuario no está conectado en ese momento, el aviso
  se pierde. El estado real siempre se consulta en la API.
  """
  require Logger

  @pubsub LevantarVuelo.PubSub

  @doc """
  Suscribe al proceso que llama a los avisos del usuario.
  Llegan como mensajes `{:notification, evento}`.
  """
  def subscribe(user_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(user_id))
  end

  @doc """
  Avisa `event` a cada usuario. No bloquea: el envío corre en una tarea aparte,
  así el FlightServer sigue atendiendo aunque haya muchos usuarios para avisar.
  """
  def notify(user_ids, event) do
    Task.Supervisor.start_child(LevantarVuelo.NotifierTasks, fn ->
      Enum.each(user_ids, fn user_id ->
        Logger.info("Notificando a #{user_id}: #{inspect(event)}")
        Phoenix.PubSub.broadcast(@pubsub, topic(user_id), {:notification, event})
      end)
    end)

    :ok
  end

  defp topic(user_id), do: "user:#{user_id}"
end
