#!/bin/sh
set -e

# Cada contenedor tiene una IP distinta y recién se conoce al arrancar.
# libcluster (DNSPoll) arma los nombres de nodo como "levantar@<ip>", así que el
# nodo tiene que llamarse exactamente así para que los demás lo encuentren.
IP=$(hostname -i | awk '{print $1}')

# --name: nombre largo de nodo (necesario cuando se usa una IP).
# --cookie: contraseña compartida. Dos nodos solo se conectan si tienen la misma.
exec elixir --name "levantar@${IP}" --cookie "${RELEASE_COOKIE:?falta RELEASE_COOKIE}" -S mix run --no-halt
