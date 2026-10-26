# Levantar Vuelo

TP grupal IASC 2C2026. Sistema de reserva de vuelos construido en Elixir/OTP.

Cada checkpoint tiene su propia carpeta con el proyecto completo tal como quedó en esa entrega, más la documentación y el debate del equipo sobre las decisiones tomadas.

---

## Checkpoints

| # | Fecha | Estado | Carpeta |
|---|---|---|---|
| 1 | 08/10 | 🔖 v1 | [checkpoint-1/](checkpoint-1/) |
| 2 | 29/10 | ✅ Listo para entregar | [checkpoint-2/](checkpoint-2/) |
| Final | 13/12 | 🔜 Pendiente | — |

Dentro de cada carpeta hay un `docs/` con las decisiones de diseño y el debate del equipo.

---

## Arquitectura general

### Idea central: un actor por vuelo

Cada vuelo es un proceso `GenServer` independiente. Su mailbox serializa todos los pedidos de ese vuelo — así dos usuarios compitiendo por el mismo asiento nunca ejecutan al mismo tiempo y no hay doble venta, sin necesidad de locks ni transacciones.

Vuelos distintos son actores distintos: se procesan en paralelo en todos los cores y nodos.

### Distribución (checkpoint 2)

El sistema corre en un cluster de nodos Erlang. Todos los nodos son iguales — no hay un master. Cualquier nodo puede recibir cualquier request y lo rutea al actor correcto. Detalle en [checkpoint-2/README.md](checkpoint-2/README.md) y decisiones en [checkpoint-2/docs/tradeoffs.md](checkpoint-2/docs/tradeoffs.md).

```
                        ┌─────────────────────────────────────┐
Clientes ──→ nginx ──→  │  Cluster Erlang (3 nodos)           │
                        │                                     │
                        │  Nodo 1          Nodo 2             │
                        │  ┌──────────┐   ┌──────────┐        │
                        │  │ API HTTP │   │ API HTTP │        │
                        │  │ Flight 1 │   │ Flight 2 │        │
                        │  │ réplicas │   │ réplicas │        │
                        │  └──────────┘   └──────────┘        │
                        └─────────────────────────────────────┘
```

**Cómo se resuelve cada problema de distribución:**

| Problema | Solución |
|---|---|
| Encontrar en qué nodo vive un vuelo | `Horde.Registry` — registro distribuido entre todos los nodos |
| Si un nodo se cae, reiniciar sus vuelos en otro | `Horde.DynamicSupervisor` — supervisor distribuido |
| Que el estado no se pierda si cae un nodo | Réplica con quórum: el actor escribe en 2 de 3 nodos antes de confirmar, con épocas para que no haya dos primarios |
| Conectar los nodos automáticamente | `libcluster` con DNS en Docker |
| Notificaciones a usuarios en cualquier nodo | SSE + `:pg` (grupos de procesos de Erlang, sincronizados entre nodos) |
| Alertas disponibles en todos los nodos | `DeltaCrdt` — replicación eventual entre nodos |

### CAP: qué elegimos según el tipo de dato

No se puede tener consistencia perfecta y disponibilidad perfecta al mismo tiempo cuando hay particiones de red. Elegimos según el impacto de cada error:

| Dato | Elección | Motivo |
|---|---|---|
| Asientos y reservas | **CP** — consistencia | Vender dos veces un asiento es el peor error posible |
| Alertas | **AP** — disponibilidad | Si tarda en propagarse, lo peor es que alguien no reciba un aviso |
| Notificaciones | **AP** — best-effort | Son avisos, el estado real se consulta en la API |

### Documentación de arquitectura

- **[docs/diagrama-actores.html](docs/diagrama-actores.html)** — diagrama de actores del checkpoint 1: Router, FlightServer, Registry, AlertIndex y sus relaciones. Ver en el navegador.
- **[docs/arquitectura-ivan.html](docs/arquitectura-ivan.html)** — diagrama interactivo completo (4 paneles: publicar vuelo, reservar con quorum, failover, topología). Ver en el navegador.
- **[Propuesta de arquitectura completa](https://github.com/IvanErazun/ASWC-Grupo-2/blob/claude/practico-architecture-design-1r5hlq/docs/arquitectura.md)** — documento de trabajo del equipo con decisiones, trade-offs y preguntas al tutor.

---

## Cómo correr cada checkpoint

```bash
cd checkpoint-1       # (o checkpoint-2, etc.)
mix deps.get
mix test              # correr los tests
mix run --no-halt     # servidor en localhost:4000
```

Con Docker:

```bash
cd checkpoint-1
docker compose up --build
```
