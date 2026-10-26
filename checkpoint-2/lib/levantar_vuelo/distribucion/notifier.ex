defmodule LevantarVuelo.Notifier do
  @moduledoc """
  Avisos a los usuarios: vuelo publicado que coincide con una alerta (F3) y
  vuelo cerrado por agotado o por fin de la oferta.

  Para avisarle a un usuario hay que saber qué procesos lo están escuchando
  (sus conexiones SSE de `GET /users/:id/events`), y pueden estar en cualquier
  nodo. Esa "agenda de oyentes" la lleva `:pg` (grupos de procesos, viene con
  Erlang): un proceso por nodo, que arranca en `application.ex`, y que se
  sincroniza solo con los de los otros nodos. Cada usuario es un grupo
  `{:user, id}`.

  Este módulo no es un proceso: son las dos funciones para anotarse en la
  agenda y para avisar.

  Es best-effort (AP): si el usuario no está conectado en ese momento, el aviso
  se pierde. El estado real siempre se consulta en la API.
  """
  require Logger

  # Nombre del proceso de :pg que lleva la agenda (lo arranca application.ex)
  @scope :avisos

  @doc """
  Anota al proceso que llama como oyente del usuario. Los avisos le llegan
  como mensajes `{:notification, evento}`. Si el proceso termina, `:pg` lo
  saca de la agenda solo.
  """
  def subscribe(user_id) do
    :pg.join(@scope, {:user, user_id}, self())
  end

  @doc """
  Le manda `event` a cada oyente de cada usuario, esté en el nodo que esté.
  No espera a que lo lean: `send` deja el mensaje en el mailbox y sigue.
  """
  def notify(user_ids, event) do
    Enum.each(user_ids, fn user_id ->
      Logger.info("Notificando a #{user_id}: #{inspect(event)}")

      for pid <- :pg.get_members(@scope, {:user, user_id}) do
        send(pid, {:notification, event})
      end
    end)
  end
end
