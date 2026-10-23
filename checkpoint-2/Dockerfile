FROM elixir:1.20-otp-29-slim

WORKDIR /app

# La imagen slim no trae certificados SSL — los necesita mix para descargar deps
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

# Instala hex y rebar (gestores de paquetes de Elixir)
RUN mix local.hex --force && mix local.rebar --force

# Copia las dependencias primero para aprovechar el cache de Docker:
# si solo cambia el código fuente, no vuelve a bajar las deps
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

# Copia el resto del código y compila
COPY lib ./lib
COPY config ./config
RUN MIX_ENV=prod mix compile

EXPOSE 4000

CMD ["mix", "run", "--no-halt"]
