# Plan — Checkpoint 2: distribución

Fecha de entrega: 29/10/2026. Plan escrito el 23/10/2026.

Este checkpoint pasa el sistema de un nodo a un cluster Erlang de 3 nodos en Docker. Los nodos se descubren por DNS (`libcluster`) y se reparten los vuelos con `Horde`. Parte del código de checkpoint-1 (copiado a `checkpoint-2/`).

---

## Índice

1. [Alcance](#1-alcance)
2. [Qué problemas trae distribuir](#2-qué-problemas-trae-distribuir)
3. [Conceptos: réplica con quórum y épocas](#3-conceptos-réplica-con-quórum-y-épocas)
4. [Conceptos: Plug, Phoenix y SSE](#4-conceptos-plug-phoenix-y-sse)
5. [Hitos](#5-hitos)
6. [Decisiones tomadas y abiertas](#6-decisiones-tomadas-y-abiertas)
7. [Riesgos](#7-riesgos)

---

## 1. Alcance

**Entra:**

- Cluster de 3 nodos en Docker, descubrimiento por DNS (`libcluster` con `DNSPoll`).
- `Horde.Registry` y `Horde.DynamicSupervisor`: cualquier nodo recibe cualquier request y lo rutea al `FlightServer`, vivo en el nodo que sea.
- Alertas replicadas en todos los nodos (`DeltaCrdt`).
- El estado de un vuelo sobrevive a la caída de un nodo: réplica con quórum y épocas (fencing).
- Notificaciones reales por SSE sobre Plug, con `Phoenix.PubSub` distribuido y un `Notifier`.
- Idempotencia de `assign_seats`, límite de mailbox y validación de body (400).
- Tests multi-nodo y un script de caos.

**No entra (queda para el final):** Prometheus/Grafana, k6, inbox persistente de notificaciones.

---

## 2. Qué problemas trae distribuir

Pasar de `Registry` a `Horde.Registry` y de `DynamicSupervisor` a `Horde.DynamicSupervisor` no alcanza. Quedan tres problemas:

| Problema | Por qué pasa | Hito que lo resuelve |
|---|---|---|
| El estado del vuelo se pierde al caer un nodo | Horde reinicia el `FlightServer` en otro nodo, pero `init/1` solo recibe `flight_attrs`. Las reservas y asientos vendidos desaparecen. | 4 |
| `AlertIndex` queda con un estado distinto en cada nodo | Es un GenServer con nombre local. Una alerta creada en A no se ve desde B. | 3 |
| Una partición de red puede dejar dos actores para el mismo vuelo | Horde es AP. `UniformQuorumDistribution` mitiga (la minoría no arranca procesos) pero no elimina. | 4 (quórum + épocas) |

---

## 3. Conceptos: réplica con quórum y épocas

### El problema que resuelve

Cuando un nodo cae, Horde revive el `FlightServer` en otro nodo, pero vacío. Para que no se pierda nada, el estado del vuelo tiene que existir en otro nodo **antes** de decirle "listo" al usuario.

### Cómo funciona

Cada nodo tiene un `ReplicaStore`: un GenServer con una tabla ETS donde guarda copias de vuelos de otros nodos. Es pasivo, solo guarda y devuelve.

```
Escritura (reserve / assign_seats / close):

  FlightServer (primario, nodo A)
    1. calcula el estado nuevo con Flight (módulo puro)
    2. version = version + 1
    3. manda {flight_id, {epoca, version}, estado} a ReplicaStore de B y de C
    4. espera acks
    5. si llegó al menos 1 ack → "commit": guarda el estado y responde 200
       si no llegó ninguno → NO guarda el estado, responde 503
       si una réplica contesta :stale_epoch → este primario ya no es el vigente:
         se detiene (let it crash) y responde 503
```

Con 3 nodos, el **quórum es 2**: el primario más un ack. Es la mayoría de 3.

- **Consecuencia 1:** toda compra confirmada vive en al menos 2 nodos. Si cae cualquiera de los 3, queda al menos una copia.
- **Consecuencia 2 (CP):** si el primario no logra el ack, rechaza la operación. Preferimos un 503 antes que confirmar algo que se puede perder.

### Recuperación (failover)

```
Cae el nodo A  →  Horde arranca el FlightServer del vuelo en el nodo B

  init/1 de B:
    1. pide a los ReplicaStore alcanzables la copia del vuelo
    2. si contestan al menos 2 nodos, se queda con la de mayor {epoca, version}
       (se compara primero la época y después la versión)
    3. si contestan menos de 2, no arranca (503): no sabe si tiene lo último
    4. epoca = epoca_máxima_vista + 1
    5. "reclama" el vuelo: replica el estado recuperado con la época nueva a quórum
    6. recién ahí empieza a atender pedidos
```

Por qué hace falta leer de 2 nodos: la escritura llegó a 2 de 3 y la lectura toca 2 de 3, así que **siempre se solapan en al menos un nodo**, y ese nodo tiene la versión confirmada más nueva (R + W > N, con N = 3).

### Épocas (fencing)

Una **época** es un número que sube cada vez que un `FlightServer` nuevo toma el control de un vuelo. Va junto a cada escritura como `{época, versión}`, y cada `ReplicaStore` guarda la mayor época que vio y **rechaza** escrituras con una época menor (`:stale_epoch`). Eso es *fencing*: deja al primario viejo "afuera" aunque todavía crea que manda.

**Qué problema cubre.** El quórum solo alcanza en el caso común, pero no en este:

| Caso | Solo quórum | Quórum + épocas |
|---|---|---|
| Partición limpia 2 vs 1 | El primario viejo en la minoría no consigue ack. ✅ | ✅ |
| El nodo cae del todo | No hay primario viejo. ✅ | ✅ |
| Primario viejo **lento pero no aislado** (pausa de GC, Horde que duplica el actor al curar una partición) conviviendo con el nuevo | Los dos juntan quórum con réplicas distintas y quedan con la misma `versión` pero contenidos distintos. ⚠️ Doble venta posible. | Al reclamar, el primario nuevo sube la época en un quórum. Cualquier escritura del viejo cae en al menos una réplica que ya vio la época nueva, la rechaza y el viejo se detiene. ✅ |

Quedan afuera de este diseño los fallos bizantinos y la pérdida de más de un nodo a la vez (ahí no hay quórum y el sistema rechaza, no confirma de más).

**Detalle a tener en cuenta.** Un primario viejo puede haber escrito en 1 sola réplica (sin quórum) y haber respondido 503. Ese estado puede aparecer en la recuperación y adoptarse, aunque el cliente nunca recibió confirmación. Es equivalente a un `:timeout` con el pedido aplicado, y lo cubre la idempotencia del hito 6.

**Qué agrega al código:**

- Un campo `epoch` en el estado del `FlightServer`.
- La comparación `{época, versión}` en `ReplicaStore.put/3` y en el desempate de `init`.
- Un paso extra en `init` (el reclamo del punto 5). Es una sola ida y vuelta al arrancar, no en cada escritura.
- Un test de fencing: dos primarios para el mismo vuelo, el viejo recibe `:stale_epoch` y se detiene.

El módulo puro `Flight` no cambia.

### Costos

- Cada escritura suma 1 ida y vuelta de red entre nodos (latencia). Las épocas solo suman otra al arrancar un vuelo.
- Cada vuelo ocupa memoria en 3 nodos.
- Si caen 2 de 3 nodos, no hay quórum y el sistema rechaza escrituras (503). Es lo que queremos para asientos.


---

## 4. Conceptos: Plug, Phoenix y SSE

Hay que reemplazar el `Logger.info("Notificando a ...")` por avisos reales al usuario. Decidimos hacerlo con SSE sobre Plug, sin migrar la capa web.

### Qué es Plug

Plug es la especificación (y librería) de Elixir para armar aplicaciones web. Un *plug* es una función, o un módulo con dos funciones, que recibe un `conn` y devuelve un `conn`. El `conn` es un struct que representa el pedido HTTP y la respuesta que se va armando. Una aplicación web es una cadena de plugs: parsear el JSON, matchear la ruta, ejecutar el handler.

- `Plug.Router` es un DSL para matchear rutas (`post "/flights" do ... end`). El `LevantarVuelo.Router` del checkpoint 1 es eso.
- Plug **no abre sockets ni habla HTTP**. De eso se encarga un servidor, que recibe las conexiones y le pasa cada pedido al plug. Usamos **Bandit**.

### Qué es Phoenix

Phoenix es un framework web completo, construido **encima de Plug** (y de Bandit o Cowboy). Agrega:

- `Endpoint` y `Router` propios, controllers, templates y generadores de código.
- **Channels**: comunicación bidireccional por WebSocket organizada en topics, con reconexión y presence (quién está conectado).
- **LiveView**: interfaces web interactivas renderizadas desde el servidor.
- Integración con Ecto (base de datos) y con `Phoenix.PubSub`.

Un **controller** es un módulo de Phoenix que agrupa los handlers de una misma cosa. Cada función (una *acción*) atiende una ruta. Es lo que hoy hace cada bloque `post "/algo" do ... end` del `Router`. No lo necesitamos con Plug.

`Phoenix.PubSub` es una librería aparte (`phoenix_pubsub`) y funciona sola, sin el framework. Manda mensajes por topics entre procesos, y entre nodos si están conectados en cluster. Es lo único de Phoenix que usamos.

### SSE (Server-Sent Events)

Es una respuesta HTTP que **no se cierra**: el servidor sigue escribiendo líneas con formato `text/event-stream` cada vez que hay algo que avisar. Es unidireccional (servidor → cliente). El navegador lo consume con `EventSource` y se reconecta solo.

```
GET /users/u1/events
< HTTP/1.1 200
< content-type: text/event-stream

event: flight_closed
data: {"flight_id":"fl_1","reason":"sold_out"}

event: flight_published
data: {"flight_id":"fl_9"}
```

### Cómo lo hacemos

El endpoint `GET /users/:id/events` hace `send_chunked(200)`, se suscribe al topic `"user:<id>"` de `Phoenix.PubSub` y queda en un loop: espera un mensaje y lo escribe con `chunk/2`. Son unas 30 líneas. La única dependencia nueva es `phoenix_pubsub`.

```
cliente ──GET /users/u1/events──▶ proceso de la request (en el nodo X)
                                      │ se suscribe a PubSub "user:u1"
FlightServer (nodo Y) ─▶ Notifier ─▶ PubSub.broadcast("user:u1", evento)
                                      │ PubSub entrega a todos los nodos
cliente ◀─ "event: flight_closed" ────┘
```

Si el usuario está conectado al nodo X y el vuelo vive en el nodo Y, `Phoenix.PubSub` entrega el mensaje entre nodos solo, una vez que están conectados.

### Por qué SSE con Plug y no Phoenix

- Las notificaciones solo van del servidor al cliente y son best-effort (el estado real se consulta con `GET /flights/:id`). Un WebSocket bidireccional no aporta nada.
- No hay que migrar la capa web: los controllers, el `Endpoint` y el resto de la estructura de Phoenix son complejidad que la distribución no necesita. Horde, libcluster, la réplica y las épocas funcionan igual con Plug.
- Se prueba con `curl -N`.
- Si más adelante se quiere Phoenix (por ejemplo para LiveDashboard en la entrega final), el cambio queda confinado a la capa web, porque las notificaciones pasan por topics de PubSub y el dominio no se entera.

**Limitaciones aceptadas:** no hay presence (saber quién está conectado) ni mensajes del cliente al servidor por el mismo canal, y no hay autenticación (cualquiera puede suscribirse al `user_id` que quiera, igual que hoy con la API REST). Existe una tercera opción, WebSocket sin Phoenix con `WebSock` de Bandit, que no se evaluó en detalle.

---

## 5. Hitos

Orden pensado para que cada hito se pueda verificar solo.

- [ ] **0. Preparación.** Commitear lo pendiente de `checkpoint-1` (8 archivos modificados, `safe_call.ex` y `router_test.exs` sin trackear). Copiar el proyecto a `checkpoint-2/`.
- [ ] **1. Cluster por DNS en Docker.**
  - Deps `libcluster` y `horde`.
  - `Cluster.Supervisor` con `Cluster.Strategy.DNSPoll` (`query: "app"`, `node_basename: "levantar"`). En local, `Epmd`, elegido por variable de entorno.
  - Cada nodo arranca con `--name levantar@<IP del contenedor>` y la misma cookie (entrypoint o `mix release` con `RELEASE_NODE` y `RELEASE_COOKIE`).
  - `docker-compose.yml`: `app` escalado con `--scale app=3`, sin puerto fijo, más `nginx` delante en el 4000. nginx debe re-resolver el DNS (`resolver 127.0.0.11` y variable en `proxy_pass`) y no bufferear el SSE (`proxy_buffering off`, `proxy_http_version 1.1` y un `proxy_read_timeout` largo).
  - **Verificación:** `Node.list()` muestra 2 nodos en cada contenedor.
- [ ] **2. Horde para vuelos.**
  - `application.ex`: `Horde.Registry` y `Horde.DynamicSupervisor` con `UniformQuorumDistribution`. Registrar miembros con un `NodeObserver` como en clase (a verificar si `members: :auto` de Horde 0.9 lo reemplaza).
  - `FlightServer`: `via` a `Horde.Registry` y `child_spec` con `flight_id` como id.
  - `router.ex`: `start_child` a Horde. Revisar qué devuelve cuando el vuelo ya existe.
  - **Verificación:** POST en un nodo, GET en otro, mismo vuelo.
- [ ] **3. Alertas replicadas.**
  - `AlertIndex` pasa a `DeltaCrdt` (AWLWWMap). `matching_users` lee la copia local.
  - Los vecinos del CRDT se actualizan con `:net_kernel.monitor_nodes`.
  - **Verificación:** alerta creada en un nodo, notificación al publicar un vuelo desde otro.
- [ ] **4. Réplica con quórum y épocas.** (ver sección 3)
  - `ReplicaStore` por nodo (GenServer + ETS) con `put/3` y `get/1`. Guarda la mayor época vista y rechaza escrituras con época menor (`:stale_epoch`).
  - `FlightServer` replica en `reserve`, `assign_seats` y `:offer_expired` antes de responder. Mensaje `{época, versión, estado}`. Si una réplica contesta `:stale_epoch`, se detiene.
  - `init` recupera la mayor `{época, versión}` con lectura de 2 nodos (o no arranca), sube la época y reclama el vuelo en un quórum antes de atender.
  - **Verificación:** matar el nodo primario de un vuelo con reservas, el vuelo reaparece en otro nodo con las mismas reservas y con la época incrementada.
  - **Test de fencing:** dos primarios para el mismo vuelo, el viejo recibe `:stale_epoch` y se detiene sin confirmar nada.
- [ ] **5. Notificaciones por SSE.** (ver sección 4)
  - Dependencia `phoenix_pubsub` y `{Phoenix.PubSub, name: LevantarVuelo.PubSub}` en `application.ex`.
  - `Notifier` con `Task.Supervisor`: el `FlightServer` solo le manda el mensaje y sigue. El `Notifier` hace `PubSub.broadcast("user:<id>", evento)`. Reemplaza los `Logger.info` del `FlightServer` y del `Router`.
  - `GET /users/:id/events` en `router.ex`: `send_chunked`, suscripción al topic y loop de `chunk/2`, con un comentario cada pocos segundos para mantener la conexión abierta detrás de nginx. Cubre F3 y F8.
  - **Verificación:** `curl -N` a un nodo recibe el aviso de un vuelo que vive en otro.
- [ ] **6. Endurecimiento.**
  - `assign_seats` idempotente: reintentar una reserva confirmada devuelve los mismos asientos. Importa porque `SafeCall` puede devolver `:timeout` con el pedido ya aplicado.
  - Límite de mailbox del `FlightServer`.
  - Validación de body con 400 (hoy es 500), y `String.to_atom` sobre input del usuario en `/seats` se cambia por una lista blanca.
- [ ] **7. Pruebas y documentación.**
  - Tests multi-nodo con `:peer` (OTP 25+).
  - Script de caos: `docker compose up --scale app=3`, matar un contenedor con carga y verificar que no se perdió ninguna compra confirmada.
  - `checkpoint-2/docs/tradeoffs.md`, README del checkpoint, actualizar el diagrama de actores.

---

## 6. Decisiones tomadas y abiertas

**Tomadas:**

| Decisión | Elección |
|---|---|
| Descubrimiento de nodos | `libcluster` con `DNSPoll` |
| Registro y supervisión distribuidos | `Horde` con `UniformQuorumDistribution` |
| Persistencia del estado | Réplica con quórum (sin base de datos) |
| Épocas (fencing) | Incluidas en el checkpoint 2: cierran la ventana de doble primario y cuestan poco |
| Capa web | Se mantiene Plug + Bandit (decidido el 23/10). Phoenix se evaluó y se descartó: su estructura no aporta a la distribución |
| Notificaciones | SSE con Plug + `Phoenix.PubSub` distribuido |
| Alertas | `DeltaCrdt` (AP) |

**Abiertas (a definir en el hito correspondiente):**

- ¿Réplicas en todos los otros nodos, o 2 elegidos por hash del `flight_id`? Con cluster fijo de 3 da lo mismo, y "todos los otros" es más simple. Se complica si se escala a más de 3.
- ¿Cómo se registran los miembros de Horde: `NodeObserver` (clase) o `members: :auto`?
- ¿`mix release` o `mix run` con entrypoint? El release es más prolijo para nombres de nodo y cookie, pero cambia el Dockerfile.
- ¿Phoenix para LiveDashboard en la entrega final? No hace falta decidirlo ahora. La propuesta original de Ivan (`docs/arquitectura-ivan.html`) asumía Phoenix, así que conviene avisarle de este cambio.

---

## 7. Riesgos

- **Tiempo.** El hito 4 es el más grande. Si no entra completo, el orden permite entregar 0 a 3 y 5 funcionando y documentar la réplica del hito 4 como pendiente. Si hay que recortar dentro del hito 4, se recorta primero el test de caos, no las épocas.
- **Reclamo en `init`.** Si no hay quórum al arrancar, el vuelo queda sin actor y devuelve 503 hasta que vuelvan los nodos. Es intencional (CP), pero hay que cubrirlo con un test.
- **Docker + nombres de nodo.** `DNSPoll` arma nombres `basename@IP`. Si el nombre del nodo no coincide con eso, los nodos no se conectan. Se verifica en el hito 1 antes de seguir.
- **SSE detrás de nginx.** Si nginx bufferea la respuesta o corta conexiones inactivas, el cliente no recibe los eventos. Se verifica en el hito 1 con un `curl -N` a través de nginx.
- **API de Horde 0.9.** Varios detalles (`already_present`, `members: :auto`) están sin verificar contra la versión instalada.
