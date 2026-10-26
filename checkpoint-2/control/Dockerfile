FROM elixir:1.20-otp-29-slim

WORKDIR /app

# La imagen slim no trae certificados SSL — los necesita mix para descargar deps
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Dependencias primero, para aprovechar el cache de Docker
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

COPY lib ./lib
RUN mix compile

EXPOSE 4001

CMD ["mix", "run", "--no-halt"]
