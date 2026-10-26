# Checkpoint 2 — Distribución

Fecha de entrega: 29/10/2026.

Este checkpoint toma el dominio del checkpoint 1 y lo reparte en un cluster de 3 nodos Erlang en Docker. Cualquier nodo atiende cualquier pedido, y un vuelo sobrevive a la caída del nodo donde vive sin perder compras confirmadas.

El plan de trabajo, hito por hito y con lo que se verificó en cada uno, está en [docs/plan.md](docs/plan.md). El porqué de cada decisión está en [docs/tradeoffs.md](docs/tradeoffs.md).

---

## Índice

1. [Qué hay en este checkpoint](#1-qué-hay-en-este-checkpoint)
2. [Cómo correrlo](#2-cómo-correrlo)
3. [Arquitectura](#3-arquitectura)
4. [Estructura del código](#4-estructura-del-código)
5. [API HTTP](#5-api-http)
6. [Demo de failover](#6-demo-de-failover)
7. [Tests](#7-tests)
8. [Documentación](#8-documentación)

---

## 1. Qué hay en este checkpoint

| Problema de distribuir | Cómo se resuelve |
|---|---|
| Los nodos se encuentran solos | `libcluster` le pregunta al DNS de Docker por `app` |
| Cualquier nodo encuentra cualquier vuelo | `Horde.Registry` (registro distribuido) |
| Si se cae un nodo, sus vuelos arrancan en otro | `Horde.DynamicSupervisor` |
| El vuelo vuelve **con** sus reservas | Réplica con quórum: cada cambio se guarda en 2 de 3 nodos antes de responder |
| Nunca dos primarios escribiendo el mismo vuelo | Épocas (fencing) |
| Las alertas se ven desde todos los nodos | `DeltaCrdt` replicado en cada nodo |
| Avisos en tiempo real, aunque el usuario esté en otro nodo | SSE + `Phoenix.PubSub` |
| Reintentar después de un error no duplica nada | `reserve` y `assign_seats` idempotentes |

También:
- Un vuelo saturado contesta 503 en vez de acumular cola.
- Los bodies inválidos dan 400.
- Hay un plano de control para levantar y bajar nodos.
- Hay tests que levantan un cluster de verdad.

Lo que **no** está (queda para la entrega final): métricas, pruebas de carga, inbox persistente de avisos y re-replicación (ver límites en [tradeoffs](docs/tradeoffs.md#límites-conocidos)).

---

## 2. Cómo correrlo

### Con Docker (el cluster)

```bash
cd checkpoint-2
docker compose up --build
```

Levanta 5 contenedores:

| Contenedor | Qué es | Puerto |
|---|---|---|
| `app-1`, `app-2`, `app-3` | Los 3 nodos del cluster | ninguno (solo red interna) |
| `nginx` | Única entrada: reparte los pedidos entre los nodos | `localhost:4000` |
| `control` | Plano de control: levanta y baja nodos | `localhost:4001` (solo local) |

Para más o menos nodos: `docker compose up --scale app=4`.

> Si `docker compose build` se queda bajando dependencias, puede ser la red: hay IPs de `repo.hex.pm` que no responden en algunas redes. Se arregla con un `docker-compose.override.yml` local (no se versiona) que fija una IP con `extra_hosts`.

### Sin Docker (un solo nodo)

```bash
cd checkpoint-2
mix deps.get
mix run --no-halt     # localhost:4000, sin cluster
```

### Consola dentro del cluster

```bash
docker compose exec app sh -c 'IP=$(hostname -i | cut -d" " -f1); iex --name consola@$IP --cookie levantar_vuelo_dev --hidden --remsh levantar@$IP'
```

```elixir
Node.list()                                               # los otros nodos
Horde.Registry.lookup(LevantarVuelo.Registry, "AR1")      # dónde vive un vuelo
LevantarVuelo.FlightServer.location("AR1")                # época, versión, réplicas
:sys.get_state(LevantarVuelo.ReplicaStore)                # copias guardadas en este nodo
```

- `--hidden` es necesario. Sin eso, la consola cuenta como un nodo más del cluster, y Horde y la réplica la usan.
- Para salir: Ctrl+C dos veces. **No** uses `:init.stop()` ni `System.halt()`: con `--remsh` corren en el nodo remoto y lo apagan.

---

## 3. Arquitectura

La idea central sigue siendo la del checkpoint 1: **un actor (`FlightServer`) por vuelo**, cuyo mailbox serializa los pedidos. Lo nuevo es que hay varios nodos y que el estado del actor se copia en otros nodos.

```
              ┌──────────── cluster Erlang (todos los nodos son iguales) ────────────┐
Cliente ─▶ nginx ─▶ │  Nodo A                   Nodo B                   Nodo C               │
 :4000              │  Router                   Router                   Router               │
                    │  FlightServer "AR1" ─────▶ ReplicaStore             ReplicaStore         │
                    │     │  replica a quórum ─────────────────────────────▶                   │
                    │  ReplicaStore             FlightServer "LA5"       ...                  │
                    │  AlertIndex (CRDT) ◀──────▶ AlertIndex (CRDT) ◀───▶ AlertIndex (CRDT)   │
                    │  PubSub ◀────────────────▶ PubSub ◀───────────────▶ PubSub              │
                    └───────────────────────────────────────────────────────────────────────┘
```

Diagrama de procesos de un nodo y de sus mensajes con los otros: [docs/diagrama-actores.html](docs/diagrama-actores.html).

### Árbol de supervisión de cada nodo

```
LevantarVuelo.Supervisor  (one_for_one)
├── Cluster.Supervisor          libcluster: conecta los nodos (solo en Docker)
├── Horde.Registry              vuelo → pid, en todo el cluster
├── AlertIndex  (rest_for_one)  alertas
│   ├── DeltaCrdt                 el mapa de alertas, replicado
│   └── CrdtNeighbours            le dice al CRDT con qué nodos sincronizar
├── Phoenix.PubSub              avisos entre nodos
├── Task.Supervisor             tareas que mandan los avisos
├── ReplicaStore                copias de vuelos (de este nodo y de otros)
├── Horde.DynamicSupervisor     los FlightServer (uno por vuelo, en cualquier nodo)
└── Bandit + Router             HTTP en el puerto 4000
```

### Escribir: reservar o elegir asientos

```
Router (nodo X) ──call──▶ FlightServer "AR1" (nodo Y, lo encuentra Horde.Registry)
                             1. Flight calcula el estado nuevo (módulo puro)
                             2. versión + 1
                             3. manda {época, versión, estado} a los ReplicaStore de 3 nodos
                             4. ¿lo guardaron 2? → adopta el estado y responde 200
                                ¿menos?          → no lo adopta, responde 503
                                ¿época vieja?    → había otro primario: se retira
```

### Recuperar: se cae el nodo de un vuelo

```
Se cae el nodo Y ──▶ Horde arranca el FlightServer "AR1" en otro nodo (vacío)
                       1. pide la copia a los ReplicaStore; necesita 2 respuestas
                       2. se queda con la de mayor {época, versión}
                       3. época + 1 y "reclama" el vuelo escribiéndola en quórum
                       4. recién ahí atiende pedidos
```

En Docker, un vuelo vuelve a responder unos 200 ms después de matar su nodo.

---

## 4. Estructura del código

```
lib/levantar_vuelo/
├── application.ex       árbol de supervisión
├── flight.ex            dominio puro del vuelo (igual que en el checkpoint 1, + idempotencia)
├── flight_server.ex     actor del vuelo: réplica, recuperación, épocas, límite de mailbox
├── replicas.ex          en qué 3 nodos va cada vuelo (rendezvous hashing) y los quórums
├── replica_store.ex     guarda copias; rechaza épocas viejas (fencing)
├── alert.ex             dominio puro de alertas
├── alert_index.ex       alertas en un DeltaCrdt
├── crdt_neighbours.ex   mantiene los vecinos del CRDT al entrar o salir nodos
├── notifier.ex          avisos por Phoenix.PubSub (topic "user:<id>")
├── sse.ex               conexión SSE: escribe un evento por aviso
├── params.ex            valida los bodies (400)
├── safe_call.ex         GenServer.call que no tira abajo al que llama
└── router.ex            API HTTP
control/                 plano de control (proyecto aparte, puerto 4001)
```

---

## 5. API HTTP

Los endpoints del checkpoint 1 siguen igual ([checkpoint-1/README.md](../checkpoint-1/README.md#5-api-http--endpoints-y-ejemplos)). Lo nuevo:

### Ver dónde vive un vuelo

```bash
curl localhost:4000/flights/AR1/location
# → 200 {"flight_id":"AR1","container":"checkpoint-2-app-2","node":"levantar@172.20.0.3",
#        "epoch":1,"version":2,"recovering":false,
#        "replicas":[{"container":"checkpoint-2-app-1",...}, ...]}
```

`replicas` son los nodos que guardaron la última escritura.

### Escuchar avisos (SSE)

```bash
curl -N localhost:4000/users/u1/events
# : conectado a levantar@172.20.0.2
#
# event: flight_published
# data: {"flight_id":"AR1"}
#
# event: flight_closed
# data: {"flight_id":"AR1","reason":"sold_out"}
```

La conexión queda abierta. Cada 15 s sin avisos llega un comentario `: ping`.

### Errores

| Código | Cuándo |
|---|---|
| 400 | Body inválido (falta un campo, fecha mal escrita, asiento desconocido) |
| 404 | El vuelo no existe |
| 409 | El vuelo ya existe, o no hay asientos |
| 410 | El vuelo está cerrado |
| 422 | Error de negocio (por ejemplo, otro pedido sobre una reserva ya confirmada) |
| 503 | Falla transitoria: sin quórum, vuelo saturado, nodo caído. Se puede reintentar: las operaciones son idempotentes |

### Plano de control (puerto 4001)

```bash
curl localhost:4001/nodes                                  # nodos, corriendo o parados
curl -X POST localhost:4001/nodes/checkpoint-2-app-2/kill  # caída abrupta
curl -X POST localhost:4001/nodes/checkpoint-2-app-2/stop  # apagado ordenado
curl -X POST localhost:4001/nodes/checkpoint-2-app-2/start
curl -X POST localhost:4001/nodes/start                    # levanta todos los parados
```

Todo esto está también en la colección de Postman: [docs/postman/](docs/postman/levantar-vuelo.postman_collection.json).

---

## 6. Demo de failover

Con el cluster levantado, desde Postman (carpetas *Vuelos*, *Reservas* y *Control de nodos*) o con curl:

1. **Crear un vuelo y comprar:** `POST /flights`, `POST /flights/AR1/reservations`, `POST /flights/AR1/reservations/r1/seats`.
2. **Ver dónde vive:** `GET /flights/AR1/location`. Postman guarda el contenedor en `{{container}}`.
3. **Matarlo:** `POST localhost:4001/nodes/{{container}}/kill`.
4. **Volver a mirar:** `GET /flights/AR1/location` muestra otro contenedor y la época + 1. `GET /flights/AR1` muestra la misma compra.
5. **CP:** matar un segundo nodo e intentar reservar. Da 503 `no_quorum`: con un solo nodo no se confirma nada.
6. **Levantar todo:** `POST localhost:4001/nodes/start`.

Para ver los avisos entre nodos, dejar abierto `curl -N localhost:4000/users/u1/events` mientras se agota un vuelo donde `u1` tiene una reserva. La primera línea dice a qué nodo se conectó; con `/location` se ve que el vuelo vive en otro.

---

## 7. Tests

```bash
mix test                    # todo: 71 tests, menos de un minuto
mix test --exclude cluster  # sin los multi-nodo: unos segundos
```

| Archivo | Qué prueba |
|---|---|
| `flight_test.exs` | Dominio: reservas, asientos, cierre, idempotencia |
| `flight_server_test.exs` | El actor: recuperación tras matarlo (época 1 → 2), fencing, avisos, límite de mailbox |
| `replica_store_test.exs` | Reglas de época y versión, quórum |
| `replicas_test.exs` | Elección de nodos: siempre 3 distintos, mismo resultado en todos los nodos |
| `alert_test.exs` | Matching de alertas y `AlertIndex` |
| `notifier_test.exs` | Entrega de avisos y formato SSE |
| `params_test.exs`, `router_test.exs` | Validación (400), endpoints, F3 |
| `cluster_test.exs` | **Multi-nodo**: levanta 3 VMs de Erlang con `:peer`. Failover con compras, CP con un nodo, alertas y avisos entre nodos |

Los tests de un solo nodo corren con factor y quórums de 1 (`config/config.exs`). Los multi-nodo usan la config real: factor 3, quórums de 2.

---

## 8. Documentación

- **[docs/plan.md](docs/plan.md)** — plan del checkpoint: conceptos (quórum, épocas, Plug y SSE), hitos y lo que se verificó en cada uno.
- **[docs/tradeoffs.md](docs/tradeoffs.md)** — decisiones, alternativas descartadas y límites conocidos.
- **[docs/diagrama-actores.html](docs/diagrama-actores.html)** — procesos de un nodo y mensajes entre nodos. Se ve en el navegador.
- **[docs/postman/](docs/postman/levantar-vuelo.postman_collection.json)** — colección de Postman.
