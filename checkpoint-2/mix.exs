defmodule LevantarVuelo.MixProject do
  use Mix.Project

  def project do
    [
      app: :levantar_vuelo,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  # En test se compila también test/support: los nodos que levantan los tests
  # multi-nodo (TestCluster) cargan esos módulos desde _build.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {LevantarVuelo.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:libcluster, "~> 3.5"},
      {:horde, "~> 0.9.0"},
      {:phoenix_pubsub, "~> 2.1"}
    ]
  end
end
