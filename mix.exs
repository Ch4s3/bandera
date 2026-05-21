defmodule Bandera.MixProject do
  use Mix.Project

  def project do
    [
      app: :bandera,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [threshold: 85],
      # Incremental Dialyzer via `mix assay`:
      assay: [
        dialyzer: [
          # `:crypto` is an OTP app used at runtime (declared in
          # `extra_applications`) but it is not part of the resolved dep tree,
          # so the `:project_plus_deps` selector omits it. Add it explicitly so
          # the PLT includes its specs and `:crypto.hash/2` resolves cleanly.
          apps: [:project_plus_deps, :crypto],
          warning_apps: :project
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Bandera.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:telemetry, "~> 1.0"},
      # Backs Bandera.Store.ProcessScoped (the test layer). optional: available in
      # Bandera's own builds; not forced on consumers. Apps using the test layer add
      # {:nimble_ownership, "~> 1.0", only: :test} to their own deps.
      {:nimble_ownership, "~> 1.0", optional: true},
      {:ecto_sql, "~> 3.10", optional: true},
      {:redix, "~> 1.1", optional: true},
      {:phoenix_pubsub, "~> 2.1", optional: true},
      {:ecto_sqlite3, "~> 0.17", only: :test},
      {:stream_data, "~> 1.0", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:assay, "~> 0.5", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end
end
