# Decisiones de diseño y tradeoffs — Checkpoint 2

Igual que en el checkpoint 1, este documento registra qué decidimos, por qué y qué descartamos. En este checkpoint el sistema pasa de un nodo a un cluster de 3: casi todas las decisiones son sobre qué pasa cuando hay varios nodos y alguno se cae.

Al final hay una sección de **límites conocidos**: cosas que el sistema no resuelve y que aceptamos a conciencia.

---

## 1. Encontrar los nodos: libcluster con el DNS de Docker

**Decisión: `Cluster.Strategy.DNSPoll`.**

**Por qué:**
Con `docker compose up --scale app=3`, el DNS interno de Docker responde al nombre `app` con la IP de cada réplica. libcluster le pregunta cada 2 segundos y se conecta a las IPs nuevas. No hay que escribir la lista de nodos en ningún lado, y escalar a 4 funciona solo.

La única condición es que cada nodo se llame `levantar@<su IP>`, porque así arma los nombres libcluster. Lo resuelve `docker/entrypoint.sh`, que lee la IP del contenedor al arrancar.

**Alternativa descartada: lista fija de nodos (`Epmd`).**
Hay que conocer los nombres de antemano y no sirve si las IPs cambian o se agregan réplicas.

---

## 2. Horde para registrar y supervisar los vuelos

**Decisión: `Horde.Registry` y `Horde.DynamicSupervisor` en lugar de `Registry` y `DynamicSupervisor`.**

**Por qué:**
Cualquier nodo tiene que poder encontrar cualquier vuelo (`Horde.Registry`), y si se cae un nodo sus vuelos tienen que volver a arrancar en otro (`Horde.DynamicSupervisor`). El cambio en el código fue chico: la línea del `via` y el `start_child`.

**Lo que hay que saber de Horde: es AP.**
Su estado (qué vuelo vive en qué proceso) es un CRDT que se sincroniza entre nodos cada cierto tiempo (lo bajamos de 300 a 100 ms). Eso tiene dos consecuencias:

- Durante un instante, otro nodo no encuentra un vuelo recién creado. `FlightServer` reintenta 3 veces cada 100 ms antes de responder 404.
- Si un nodo se cae antes de contarle a los demás que arrancó un vuelo, nadie lo reinicia (ver límites).

Además, Horde reinicia el vuelo **vacío**: arranca un proceso nuevo con los datos de creación, sin las reservas. Por eso hace falta la réplica (punto 3).

**Opciones que elegimos:**
- `UniformQuorumDistribution`: un nodo aislado de la mayoría apaga sus procesos.
- `process_redistribution: :passive` (el valor por defecto): con `:active`, cuando entra un nodo Horde mueve vuelos hacia él, matándolos y arrancándolos de nuevo. Sería un failover innecesario.

---

## 3. Réplica con quórum: los asientos son CP

**Decisión: cada cambio de un vuelo se copia en 3 nodos y se confirma cuando lo guardaron 2 (W = 2). Para recuperar un vuelo se leen 2 copias (R = 2).**

**Por qué:**
Como R + W > N (2 + 2 > 3), la escritura confirmada y la lectura de recuperación siempre comparten al menos un nodo, y ese nodo tiene la última versión. Toda compra confirmada sobrevive a la caída de cualquier nodo.

**Costo:**
- Cada escritura suma una ida y vuelta de red. Las lecturas no, porque salen de la memoria del primario.
- Cada vuelo ocupa memoria en 3 nodos.
- Si se caen 2 de 3 nodos no se puede escribir (503). Es justamente la elección CP: preferimos rechazar a confirmar algo que se puede perder.

**Detalle de implementación:** `GenServer.multi_call` espera a los 3 nodos (o hasta 1 s), no al segundo que contesta. Es más simple, pero un nodo lento demora todas las escrituras hasta ese segundo.

**Alternativas descartadas:**
- Base de datos externa: resolvería la persistencia, pero saca del TP justamente el problema de distribución.
- Sin réplica: un vuelo vuelve vacío cada vez que se cae su nodo.

---

## 4. Épocas (fencing): un solo primario por vuelo

**Problema:**
Puede haber dos procesos del mismo vuelo a la vez. Por ejemplo, el viejo quedó trabado por una pausa larga, o una partición de red se curó y Horde ve los dos. Si los dos escriben, cada uno puede juntar quórum con réplicas distintas: doble venta.

**Decisión: cada copia lleva un sello `{época, versión}`.**
- La época sube cada vez que un proceso nuevo toma el vuelo. Al recuperarse, el proceso "reclama" el vuelo escribiendo su época nueva en quórum.
- Cada `ReplicaStore` rechaza escrituras con una época menor a la que ya vio (`:stale_epoch`).
- El primario viejo, al recibir ese rechazo, se detiene con `{:shutdown, :stale_epoch}`. Con ese motivo, Horde no lo reinicia.

**Costo:** un paso extra al arrancar un vuelo, no en cada escritura.

---

## 5. Dónde van las copias: rendezvous hashing

**Decisión: factor 3, elegido por hash.** Cada nodo recibe el puntaje `hash({vuelo, nodo})` y las copias van a los 3 de mayor puntaje (`Replicas.nodes_for/1`).

**Por qué:**
- Con 3 nodos son los 3. Con 4 o más, cada vuelo usa 3 y la carga se reparte.
- Todos los nodos calculan lo mismo sin hablar entre ellos.
- Cuando entra o sale un nodo, solo cambian de lugar las copias de los vuelos afectados.

**Alternativas descartadas:**
- "En todos los otros nodos": más simple con 3 fijos, pero al escalar el quórum dejaría de ser 2 de 3.
- `libring`, el hash ring que trae Horde: su `key_to_nodes/3` no da la vuelta al final del anillo. Con 3 nodos, 61 de cada 10.000 vuelos recibían 1 o 2 nodos en vez de 3, y con quórum 2 algunos no se podrían escribir nunca. Hay un test que cubre esto.

---

## 6. La recuperación no bloquea a Horde, y sin quórum el vuelo no se cae

**Decisión:** `init` devuelve enseguida y la recuperación corre en `handle_continue`. Si no hay quórum, el vuelo contesta 503 a todo y reintenta cada 1 s.

**Por qué:**
- `init` bloquea al supervisor que está arrancando el proceso, y recuperar implica hablar con otros nodos.
- Si la recuperación fallara tirando el proceso, Horde lo reiniciaría en loop hasta agotar sus reinicios.

Además, `POST /flights` responde 201 recién cuando el vuelo terminó de reclamarse en quórum. Crear un vuelo también es CP.

---

## 7. Alertas: DeltaCrdt (AP)

**Decisión: un `DeltaCrdt` (AWLWWMap) con todas las alertas, copiado en cada nodo.** Cada nodo busca coincidencias en su copia local.

**Por qué:**
Crear una alerta no depende de otros nodos, y un nodo nuevo recibe todas las que ya existían. Es la elección AP del checkpoint 1: si un aviso se pierde, no es grave.

**Costo:** una alerta tarda hasta unos 100 ms en llegar a los otros nodos. Si en ese lapso se publica un vuelo que coincide desde otro nodo, ese usuario no recibe el aviso.

**Detalle:** DeltaCrdt no sabe qué nodos existen. `CrdtNeighbours` le pasa la lista de vecinos cada vez que entra o sale un nodo, igual que hace `Horde.NodeListener` para Horde.

**Alternativa descartada: quórum, como los asientos.** El costo de consistencia no se justifica para un aviso.

---

## 8. Notificaciones: SSE y Phoenix.PubSub

**Decisión:** `GET /users/:id/events` deja abierta la respuesta (SSE sobre Plug). Los avisos viajan por `Phoenix.PubSub`, y el `Notifier` los manda desde un `Task.Supervisor`.

**Por qué:**
- Los avisos van en un solo sentido y son best-effort. SSE alcanza y se prueba con `curl -N`.
- PubSub los entrega entre nodos sin hacer nada extra: el usuario puede estar conectado a un nodo y el vuelo vivir en otro.
- Resuelve el punto 5 del checkpoint 1: el `FlightServer` ya no espera a notificar.

**Alternativa descartada: WebSocket con Phoenix Channels.** Es bidireccional, que no hace falta, y obligaba a migrar la capa web a Phoenix.

**Límite:** si el usuario no está conectado, el aviso se pierde. No hay inbox.

---

## 9. Idempotencia: reintentar siempre es seguro

**Problema:** un `:timeout` o un 503 no dicen si el pedido se aplicó. Por ejemplo, la escritura pudo llegar a una réplica sin llegar a quórum, y aparecer después en una recuperación. El cliente tiene que poder reintentar sin duplicar nada.

**Decisión:**
- `reserve`: el mismo `reservation_id` del mismo usuario no cambia nada.
- `assign_seats`: la reserva guarda el pedido. Repetir el mismo pedido devuelve los mismos asientos, aunque esa compra haya agotado el vuelo.

---

## 10. Límite de mailbox (load shedding)

**Decisión:** si un `FlightServer` tiene más de 1.000 pedidos en cola, contesta 503 enseguida en vez de atenderlos.

**Por qué:**
Un actor por vuelo atiende de a un pedido, y cada escritura espera a las réplicas. Si un vuelo muy demandado acumula cola, los últimos esperarían más que el timeout del cliente (5 s): se procesarían para nadie. Mejor fallar rápido y que reintenten.

**Costo:** en un pico, algunos clientes reciben 503 en vez de esperar.

---

## 11. Validación de entrada

**Decisión:** el módulo `Params` valida cada body y el router contesta 400 con un mensaje. Antes, un body incompleto daba 500.

Los asientos pasan por una lista blanca en vez de `String.to_atom/1`. Los átomos nunca se liberan: un cliente mandando textos distintos podía llenar la tabla de átomos y tirar la VM.

---

## 12. Plano de control aparte

**Decisión:** un servicio separado (`control/`, puerto 4001) levanta y baja contenedores con el socket de Docker.

**Por qué:** manejar contenedores no es responsabilidad del sistema de vuelos. Sirve para las demos de failover, y es la base para evaluar autoscaling en la entrega final.

**Riesgo:** el socket de Docker da control total sobre los contenedores de la máquina. Por eso el servicio escucha solo en localhost y solo acepta contenedores del servicio `app` de este proyecto.

---

## Límites conocidos

| Límite | Qué pasa | Por qué lo aceptamos |
|---|---|---|
| **Sin re-replicación** | Un nodo que vuelve de una caída (o uno nuevo) no tiene las copias. Las recibe recién con la próxima escritura de cada vuelo. Si mientras tanto se cae otro nodo, se puede perder lo último de un vuelo. | Se implementó y se sacó para que el `FlightServer` se entienda mejor. En sistemas reales se llama *anti-entropía* o *read repair*. |
| **Vuelo huérfano** | Si el nodo de un vuelo se cae menos de ~100 ms después de crearlo, Horde no llegó a avisar a los otros nodos y nadie lo reinicia: 404 para siempre, aunque los datos estén en las réplicas. | Lo encontramos con los tests multi-nodo. Se puede resolver con un proceso que revise las réplicas y reviva los vuelos sin proceso; lo probamos y lo descartamos por complejo para el TP. |
| **Lecturas sin quórum** | `GET /flights/:id` contesta desde la memoria del primario. En una partición, un primario aislado puede devolver datos viejos. | Las escrituras sí son CP, que es lo que protege de la doble venta. |
| **Dos nodos caídos** | Con 1 de 3 nodos no se confirma nada (503). | Es la elección CP. |
| **Un `ReplicaStore` por nodo** | Todas las copias de un nodo pasan por un solo proceso, que puede ser un cuello de botella. | Alcanza para la carga del TP. Se podría partir en varios procesos o usar ETS. |
| **Nodos de diagnóstico** | Horde y la réplica cuentan cualquier nodo visible. Un `iex --remsh` común se vuelve miembro del cluster. | Para inspeccionar, conectarse con `--hidden`. |

---

## Pendiente para la entrega final

| Tema | Notas |
|---|---|
| Métricas con Prometheus y Grafana | |
| Pruebas de carga con k6 | Ver cuándo aparece el límite de mailbox |
| Inbox persistente de notificaciones | Hoy los avisos son best-effort |
| Re-replicación | Ver límites conocidos |
| Autoscaling | Kubernetes (HPA) o extender el plano de control. Ojo: los nodos tienen estado. Hay que bajarlos de a uno y, sin re-replicación, esperar a que los vuelos vuelvan a escribirse. |
