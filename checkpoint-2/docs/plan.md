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

Cada nodo tiene un `ReplicaStore`: un GenServer que guarda copias de vuelos (de cualquier nodo, incluido el propio). Es pasivo, solo guarda y devuelve.

Cada vuelo se copia en **3 nodos** (el *factor*), elegidos por `Replicas.nodes_for/1` con rendezvous hashing: cada nodo recibe el puntaje `hash({flight_id, nodo})` y ganan los 3 más altos. Todos los nodos calculan lo mismo sin hablar entre ellos, y cuando entra o sale un nodo solo se mueven las copias de los vuelos afectados. Con 3 nodos son los 3; con más, 3 de ellos. El nodo donde Horde puso al `FlightServer` no tiene por qué estar entre los 3: el quórum se cuenta sobre los `ReplicaStore`.

```
Escritura (reserve / assign_seats / close):

  FlightServer (primario)
    1. calcula el estado nuevo con Flight (módulo puro)
    2. version = version + 1
    3. manda {flight_id, {epoca, version}, estado} a los ReplicaStore de los 3 nodos
    4. espera las respuestas (GenServer.multi_call, timeout 1 s)
    5. si guardaron al menos 2 → "commit": adopta el estado y responde 200
       si guardaron menos → NO adopta el estado, responde 503 (la versión avanza igual)
       si una réplica contesta :stale_epoch → este primario ya no es el vigente:
         se detiene con {:shutdown, :stale_epoch} (Horde no lo reinicia) y responde 503
```

El **quórum de escritura es 2**, la mayoría de 3. Factor y quórums están en `config/config.exs`.

- **Consecuencia 1:** toda compra confirmada vive en al menos 2 nodos. Si cae cualquiera de los 3, queda al menos una copia.
- **Consecuencia 2 (CP):** si no se llega a 2 copias, se rechaza la operación. Preferimos un 503 antes que confirmar algo que se puede perder.

### Recuperación (failover)

```
Cae el nodo A  →  Horde arranca el FlightServer del vuelo en el nodo B

  init/1 de B: se suscribe a nodeup/nodedown y sigue en handle_continue
  (para no frenar a Horde mientras habla con otros nodos):
    1. pide la copia del vuelo a los ReplicaStore de sus 3 nodos
    2. si contestan al menos 2, se queda con la de mayor {epoca, version}
       (se compara primero la época y después la versión). Si nadie la tiene,
       es un vuelo nuevo: arranca de cero con los attrs
    3. si contestan menos de 2, contesta 503 a todo y reintenta cada 1 s:
       no sabe si tiene lo último
    4. epoca = epoca_máxima_vista + 1
    5. "reclama" el vuelo: replica el estado recuperado con la época nueva a quórum
    6. recién ahí empieza a atender pedidos
```

Por qué hace falta leer de 2 nodos: la escritura llegó a 2 de 3 y la lectura toca 2 de 3, así que **siempre se solapan en al menos un nodo**, y ese nodo tiene la versión confirmada más nueva (R + W > N, con N = 3).

### Re-replicación

El primario anota qué nodos **confirmaron** tener la copia de la versión actual. Si a alguno de los 3 que la deberían tener le falta, se la reenvía cada 1 s hasta que la tenga. Pasa en dos casos:

- **Entra un nodo** (escalado, o vuelve uno caído): puede pasar a ser uno de los 3 de un vuelo. La VM de Erlang se conecta al cluster unos segundos antes de que arranque la aplicación, así que el primer envío suele fallar; el reintento lo completa.
- **Sale un nodo**: deja de contar como réplica (si vuelve, vuelve vacío), y con más de 3 nodos otro pasa a ser uno de los 3.

Sin esto, después de un cambio de nodos una recuperación podría leer justo de 2 nodos sin la última copia.

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

**Lecturas.** `GET /flights/:id` lee de la memoria del primario, sin quórum. El primario solo adopta estados confirmados, así que es lo último que confirmó *él*. En una partición, un primario aislado sigue contestando lecturas aunque del otro lado ya haya uno nuevo, y esas lecturas pueden estar viejas. Las escrituras no: necesitan quórum.

**Qué agrega al código:**

- Un campo `epoch` en el estado del `FlightServer`.
- La comparación `{época, versión}` en el `put` del `ReplicaStore` y en el desempate de la recuperación.
- Un paso extra en la recuperación (el reclamo del punto 5). Es una sola ida y vuelta al arrancar, no en cada escritura.
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

- [x] **0. Preparación.** Commitear lo pendiente de `checkpoint-1` (8 archivos modificados, `safe_call.ex` y `router_test.exs` sin trackear). Copiar el proyecto a `checkpoint-2/`.
- [x] **1. Cluster por DNS en Docker.** Hecho el 23/10. Se resolvió con `docker/entrypoint.sh` (sin `mix release`). `Epmd` para uso local quedó afuera: los tests multi-nodo usarán `:peer`. Verificado: cada nodo ve a los otros dos, y un vuelo creado por nginx solo existe en un nodo (3 de cada 8 GET dan 404), que es lo que arregla el hito 2.
  - Deps `libcluster` y `horde`.
  - `Cluster.Supervisor` con `Cluster.Strategy.DNSPoll` (`query: "app"`, `node_basename: "levantar"`). En local, `Epmd`, elegido por variable de entorno.
  - Cada nodo arranca con `--name levantar@<IP del contenedor>` y la misma cookie (entrypoint o `mix release` con `RELEASE_NODE` y `RELEASE_COOKIE`).
  - `docker-compose.yml`: `app` escalado con `--scale app=3`, sin puerto fijo, más `nginx` delante en el 4000. nginx debe re-resolver el DNS (`resolver 127.0.0.11` y variable en `proxy_pass`) y no bufferear el SSE (`proxy_buffering off`, `proxy_http_version 1.1` y un `proxy_read_timeout` largo).
  - **Verificación:** `Node.list()` muestra 2 nodos en cada contenedor.
- [x] **2. Horde para vuelos.** Hecho el 26/10.
  - `application.ex`: `Horde.Registry` y `Horde.DynamicSupervisor` con `UniformQuorumDistribution` y `members: :auto`. Se verificó en el código de Horde 0.9.1 que `:auto` reemplaza al `NodeObserver` de clase, que no hace falta.
  - `FlightServer`: `via` a `Horde.Registry`.
  - `router.ex`: `start_child` a Horde. Si el vuelo ya existe devuelve `{:error, {:already_started, pid}}` (409, igual que antes). Los errores nuevos `:quorum_not_met` y `:no_alive_nodes` dan 503. La búsqueda de alertas usa `Flight.new(attrs)` y no consulta al `FlightServer`, porque el registro distribuido tarda un instante en propagarse.
  - **Verificado en Docker (3 nodos):** 12 `GET` seguidos por nginx dan 200 (antes 3 de 8); el `POST` repetido da siempre 409; 6 reservas llegadas por nodos distintos suman en el mismo vuelo.
  - **Failover medido:** al matar el nodo donde vive un vuelo, Horde lo reinicia en otro nodo y vuelve a responder en 1,2 a 1,5 s (5 de 5 intentos). **Reinicia con el estado vacío** (sin reservas): eso lo resuelve el hito 4.
  - **Qué se aprendió de Horde 0.9.1:**
    - El `id` del child spec se **randomiza**: lo que evita dos procesos para el mismo vuelo es el nombre registrado (`via`), no el `id`.
    - El nodo se elige por un hash de los argumentos de `start_link` (los datos del vuelo), así que es estable para un mismo vuelo.
    - `UniformQuorumDistribution` apaga los procesos de un nodo que queda aislado de la mayoría. Hay que tenerlo en cuenta en el hito 4.
    - Se dejó `process_redistribution` en `:passive` (el valor por defecto) a propósito. Con `:active`, Horde mata y reinicia los vuelos cuando entra un nodo nuevo, y hoy eso perdería el estado.
    - `members: :auto` suma **todos los nodos visibles**, no solo los de la app. Un `iex --remsh` o un nodo de diagnóstico se vuelve miembro de Horde. Hay que conectarse con `--hidden`.
- [x] **3. Alertas replicadas.** Hecho el 26/10.
  - `AlertIndex` pasa a ser un `Supervisor` (`rest_for_one`) con dos hijos: el `DeltaCrdt` (AWLWWMap, `sync_interval: 100`) y `CrdtNeighbours`. Si se reinicia el CRDT, también se reinicia `CrdtNeighbours`, porque el CRDT nuevo arranca sin vecinos. La API (`add`, `remove`, `matching_users`) no cambió, así que el `Router` no se tocó. `matching_users` lee la copia local.
  - `CrdtNeighbours`: los vecinos del CRDT se actualizan con `:net_kernel.monitor_nodes`. Un vecino es `{nombre, nodo}`; si en ese nodo el CRDT todavía no arrancó, DeltaCrdt lo reintenta en cada sincronización.
  - `SafeCall.run/1`: el mismo manejo de exits que `SafeCall.call/3`, para cuando el `GenServer.call` lo hace una librería por dentro (`DeltaCrdt.put`).
  - **Verificado en Docker (pegándole a cada nodo por IP):** alerta creada en app-1 → vuelos publicados en app-2 y app-3 notifican a 1 usuario; alerta borrada desde app-3 → un vuelo publicado en app-1 notifica a 0. Al escalar a 4 nodos, el nodo nuevo ya tenía las alertas creadas antes de que existiera.
  - **Límite aceptado (AP):** una alerta tarda hasta ~100 ms en llegar a los otros nodos. Si en ese lapso se publica un vuelo que coincide desde otro nodo, ese usuario no recibe el aviso.
- [x] **4. Réplica con quórum y épocas.** Hecho el 26/10. (ver sección 3)
  - `Replicas`: elige los 3 nodos de cada vuelo con rendezvous hashing y lee factor y quórums de la config. Se descartó libring: su `key_to_nodes/3` no da la vuelta al anillo y, con 3 nodos, 61 de cada 10.000 vuelos recibían 1 o 2 nodos en vez de 3 (hay un test que lo cubre).
  - `ReplicaStore` por nodo: GenServer con un mapa (sin ETS: todos los accesos llegan por `multi_call`). `replicate/4` exige quórum; `put_all/4` no, y se usa para completar copias. Guarda la mayor `{época, versión}` y rechaza épocas menores (`:stale_epoch`).
  - `FlightServer` replica en `reserve`, `assign_seats` y `:offer_expired` antes de responder. Si el estado no cambió (reserva reintentada) no replica. Si una réplica contesta `:stale_epoch`, se detiene con `{:shutdown, :stale_epoch}`.
  - La recuperación corre en `handle_continue` (no en `init`). Sin quórum el proceso **no se cae**: contesta 503 y reintenta cada 1 s. Si se cayera, Horde lo reiniciaría en loop.
  - Re-replicación cuando entra o sale un nodo (sección 3).
  - De paso: `:offer_expired` sobre un vuelo ya agotado lo pasaba de `{:closed, :sold_out}` a `{:closed, :expired}`. Ahora se ignora.
  - Router: `:no_quorum` y `:stale_epoch` dan 503.
  - `GET /flights/:id/location` (también en la colección de Postman): contenedor donde vive el vuelo, época, versión y contenedores con copia. El nombre sale del DNS de Docker al revés (IP → contenedor) con `:inet_res`, porque `:inet` mira antes `/etc/hosts` y para la IP propia devuelve el ID del contenedor. Verificado: antes de matar el contenedor, app-1 con época 1 y 3 copias; después, app-2 con época 2 y 2 copias; al revivir app-1, 3 copias otra vez.
  - **Tests (52, un solo nodo con factor 1):** reglas de época y versión del `ReplicaStore`, elección de nodos (cantidad, determinismo, estabilidad), recuperación tras matar el proceso (mismas reservas, época 1 → 2) y fencing (el primario viejo recibe `:stale_epoch`, se detiene y no confirma nada).
  - **Verificado en Docker (3 nodos):**
    - Al matar el nodo de un vuelo con 3 escrituras, vuelve a responder en ~200 ms (en el hito 2 eran 1,2 a 1,5 s), en otro nodo, con época 2 y versión 3.
    - Con 2 nodos se sigue escribiendo. Después de revivir el nodo caído y matar al segundo primario, el vuelo vuelve con época 3, versión 5 y las 3 reservas.
    - Leyendo el `ReplicaStore` de cada nodo, los 3 tienen la copia `{3, 5}`, incluido el que acababa de revivir. Eso confirma la re-replicación: en una primera corrida el nodo revivido quedó sin copia, y de ahí salió el reintento.
    - Con 1 solo nodo vivo, reservar da 503 `no_quorum`. Al volver un segundo nodo se puede reservar de nuevo, y la reserva rechazada no quedó guardada.
  - **Visto en Docker, de antes de este hito:** un `POST /flights/:id/reservations` justo después del `POST /flights` puede dar 404 si nginx lo manda a otro nodo, porque `Horde.Registry` tarda un instante en propagar el registro. Ver riesgos.
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
| Dónde van las réplicas | Factor 3 por rendezvous hashing, quórum de escritura y de lectura 2 (decidido el 26/10, pensando en escalar a más de 3 nodos) |
| Épocas (fencing) | Incluidas en el checkpoint 2: cierran la ventana de doble primario y cuestan poco |
| Capa web | Se mantiene Plug + Bandit (decidido el 23/10). Phoenix se evaluó y se descartó: su estructura no aporta a la distribución |
| Notificaciones | SSE con Plug + `Phoenix.PubSub` distribuido |
| Alertas | `DeltaCrdt` (AP) |

**Abiertas (a definir en el hito correspondiente):**

- ¿Phoenix para LiveDashboard en la entrega final? No hace falta decidirlo ahora. La propuesta original de Ivan (`docs/arquitectura-ivan.html`) asumía Phoenix, así que conviene avisarle de este cambio.

---

## 7. Riesgos

- **Tiempo.** El hito 4 es el más grande. Si no entra completo, el orden permite entregar 0 a 3 y 5 funcionando y documentar la réplica del hito 4 como pendiente. Si hay que recortar dentro del hito 4, se recorta primero el test de caos, no las épocas.
- **Reclamo al arrancar.** Si no hay quórum, el vuelo contesta 503 y reintenta cada 1 s hasta que vuelvan los nodos. Es intencional (CP). Verificado en Docker para escrituras; falta un test automático, que necesita varios nodos (hito 7).
- **404 justo después de crear un vuelo.** `Horde.Registry` propaga el registro con un CRDT, así que durante un instante los otros nodos no encuentran el vuelo recién creado y un pedido que llega por otro nodo da 404. Opciones: bajar el `sync_interval` del registro (lo achica, no lo elimina) o que el router reintente un `:not_found` durante unos cientos de ms. Para el hito 6.
- **Docker + nombres de nodo.** `DNSPoll` arma nombres `basename@IP`. Si el nombre del nodo no coincide con eso, los nodos no se conectan. Se verifica en el hito 1 antes de seguir.
- **SSE detrás de nginx.** Si nginx bufferea la respuesta o corta conexiones inactivas, el cliente no recibe los eventos. Se verifica en el hito 1 con un `curl -N` a través de nginx.
- **Vuelo reiniciado sin registrar (sin explicar).** En una corrida de prueba, tras matar el nodo, Horde reinició el `FlightServer` en otro nodo pero la tabla de claves de `Horde.Registry` quedó vacía: el proceso vivía y nadie lo encontraba por nombre (siempre 404). No se pudo reproducir en 5 intentos posteriores. Esa corrida tenía varios nodos de diagnóstico *visibles* entrando y saliendo de la membresía. Hipótesis sin confirmar: Horde borra del CRDT las claves de un miembro que se va (`registry_impl.ex`) y eso pisa un registro recién hecho. Se mitiga en el hito 4 verificando el registro tras cada failover en el test de caos, repetido varias veces. Si reaparece, el `FlightServer` puede re-registrarse periódicamente.
