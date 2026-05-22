defmodule Bandera.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/ch4s3/bandera"

  def project do
    [
      app: :bandera,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Feature flag library with runtime config for storage backends and caching.",
      package: package(),
      source_url: @source_url,
      docs: docs(),
      # Coverage runs through ExCoveralls (badge + coveralls.io upload). The 85%
      # threshold and the excluded files (the compile-time Router macro and the
      # test-only dashboard scaffolding) live in coveralls.json `skip_files` /
      # `coverage_options`, since ExCoveralls filters by file path, not module.
      test_coverage: [tool: ExCoveralls],
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

  # Run the ExCoveralls mix tasks in :test by default (so `mix coveralls` works
  # locally without a leading `MIX_ENV=test`).
  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        "coveralls.github": :test
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extra_section: "GUIDES",
      extras: extras(),
      groups_for_extras: groups_for_extras(),
      groups_for_modules: groups_for_modules()
    ]
  end

  defp extras do
    [
      "README.md",
      "guides/phoenix_liveview_guide.md": [title: "Using Bandera with Phoenix LiveView"],
      "guides/dashboard_guide.md": [title: "Flag Dashboard (LiveView UI)"],
      "guides/migration_guide.md": [title: "Migration from fun_with_flags"],
      "CHANGELOG.md": [title: "Changelog"]
    ]
  end

  defp groups_for_extras do
    [
      Guides: ~r/guides\/.?/
    ]
  end

  defp groups_for_modules do
    [
      Stores: [
        Bandera.Store,
        Bandera.Store.TwoLevel,
        Bandera.Store.ProcessScoped,
        Bandera.Store.Cache
      ],
      Persistence: [
        Bandera.Store.Persistent,
        Bandera.Store.Persistent.Memory,
        Bandera.Store.Persistent.Ecto,
        Bandera.Store.Persistent.Redis,
        Bandera.Ecto.Migrations
      ],
      Notifications: [
        Bandera.Notifications,
        Bandera.Notifications.Redis,
        Bandera.Notifications.PhoenixPubSub
      ],
      Protocols: [
        Bandera.Actor,
        Bandera.Group
      ],
      Dashboard: [
        Bandera.Dashboard.Router,
        Bandera.Dashboard.FlagsLive,
        Bandera.Dashboard.Components,
        Bandera.Dashboard.Grouping,
        Bandera.Dashboard.Theme
      ],
      Testing: [
        Bandera.Test
      ]
    ]
  end

  defp package do
    [
      maintainers: ["Chase Gilliam"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Migration guide" => "#{@source_url}/blob/main/guides/migration_guide.md",
        "Phoenix LiveView guide" => "#{@source_url}/blob/main/guides/phoenix_liveview_guide.md"
      },
      files: ~w(.formatter.exs mix.exs README.md CHANGELOG.md LICENSE.md guides lib)
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
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:ecto_sqlite3, "~> 0.17", only: :test},
      {:stream_data, "~> 1.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:assay, "~> 0.5", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      # Dev-only HTTP server for the local dashboard preview (dev/preview.exs).
      {:bandit, "~> 1.0", only: :dev}
    ]
  end
end
