if Code.ensure_loaded?(Ecto.Migration) do
  defmodule Bandera.Ecto.Migrations do
    @moduledoc """
    Helpers for creating Bandera's tables. Call from your own migration:

        defmodule MyApp.Repo.Migrations.CreateBandera do
          use Ecto.Migration
          def up, do: Bandera.Ecto.Migrations.up()
          def down, do: Bandera.Ecto.Migrations.down()
        end

    `up/1` creates both the flags table and the usage table (for stale-flag
    detection). Existing installs that already have the flags table can add just
    the usage table via `up_usage/1` from a new migration.

    Every function takes an options keyword list: `:table` (the flags table),
    `:usage_table`, and `:prefix` (a Postgres schema; the schema itself must
    already exist — these helpers never create one). Any option left unspecified
    falls back to the DEFAULT Bandera instance's configured names, read at
    runtime from `config :bandera, persistence: [...]` (`ecto_table_name`,
    default `"bandera_flags"`; `usage_table_name`, default `"bandera_usage"`;
    `prefix`), exactly as before these options existed — so every zero-arity call
    below keeps working unchanged.

    For a named instance, or any table/schema other than the default instance's,
    pass the options explicitly:

        defmodule MyApp.Repo.Migrations.CreateMyAppFlags do
          use Ecto.Migration

          def up,
            do: Bandera.Ecto.Migrations.up(table: "my_app_flags", usage_table: "my_app_usage")

          def down,
            do: Bandera.Ecto.Migrations.down(table: "my_app_flags", usage_table: "my_app_usage")
        end
    """

    import Ecto.Migration

    @doc """
    Creates the flags table (and its index) plus the usage table, idempotently.

    Call from the `up/0` of your own migration. Accepts `:table`, `:usage_table`,
    and `:prefix` (see the moduledoc); unspecified options fall back to the
    default instance's configured names. New installs get everything in one
    migration; uses `create_if_not_exists` throughout so it is safe on all SQL
    backends.
    """
    @spec up(keyword) :: :ok
    def up(opts \\ []) do
      table_name = table_name(opts)
      prefix = prefix(opts)

      create_if_not_exists table(table_name, prefix: prefix) do
        add(:flag_name, :string, null: false)
        add(:gate_type, :string, null: false)
        add(:target, :string, null: false)
        add(:enabled, :boolean, null: false)
        add(:value, :string)
      end

      create_if_not_exists(
        unique_index(table_name, [:flag_name, :gate_type, :target],
          name: :"#{table_name}_flag_name_gate_target_idx",
          prefix: prefix
        )
      )

      up_usage(opts)

      :ok
    end

    @doc """
    Add the schema-v2 `value` column to an existing flags table.

    Call once from the `up/0` of a versioned migration in an existing install:

        defmodule MyApp.Repo.Migrations.UpgradeBanderaV2 do
          use Ecto.Migration
          def up, do: Bandera.Ecto.Migrations.upgrade_v2()
        end

    Accepts `:table` and `:prefix` (see the moduledoc). Uses a plain `add/2` (not
    `add_if_not_exists/2`) so it works on adapters such as SQLite3 that reject
    conditional column additions; migration versioning ensures it runs only once.
    """
    @spec upgrade_v2(keyword) :: :ok
    def upgrade_v2(opts \\ []) do
      alter table(table_name(opts), prefix: prefix(opts)) do
        add(:value, :string)
      end

      :ok
    end

    @doc """
    Fixes boolean gate rows left by a FunWithFlags-to-Bandera migration.

    FunWithFlags stored boolean gates with a legacy `target` value; Bandera uses
    `"_bandera_none"`. Because the Ecto adapter's upsert conflict target is
    `(flag_name, gate_type, target)`, toggling a flag via Bandera after migration
    inserts a second boolean row rather than updating the legacy one. This leaves
    two rows with contradictory `enabled` values, causing the dashboard toggle and
    summary to disagree and making the toggle appear broken.

    Run once from a migration after switching to Bandera:

        defmodule MyApp.Repo.Migrations.FixFunWithFlagsBooleanGates do
          use Ecto.Migration
          def up, do: Bandera.Ecto.Migrations.fix_fun_with_flags_boolean_gates()
          def down, do: :ok
        end

    Accepts `:table` and `:prefix` (see the moduledoc); the qualified table name is
    interpolated into raw SQL. Safe to run on a database that has already been
    fully migrated — it will find nothing to change. Not reversible (`down` should
    be a no-op).
    """
    @spec fix_fun_with_flags_boolean_gates(keyword) :: :ok
    def fix_fun_with_flags_boolean_gates(opts \\ []) do
      table = qualified_table(opts)
      # `table` is developer-controlled config; '_bandera_none' is a fixed sentinel.

      # When both a legacy row and a Bandera row exist for the same flag, delete
      # the legacy row. The Bandera row reflects the most recent intent.
      execute("""
      DELETE FROM #{table}
      WHERE gate_type = 'boolean'
        AND target != '_bandera_none'
        AND flag_name IN (
          SELECT flag_name FROM #{table}
          WHERE gate_type = 'boolean' AND target = '_bandera_none'
        )
      """)

      # Rename any remaining legacy rows so future Bandera writes upsert correctly.
      execute("""
      UPDATE #{table}
      SET target = '_bandera_none'
      WHERE gate_type = 'boolean'
        AND target != '_bandera_none'
      """)

      :ok
    end

    @doc """
    Creates the usage table for durable stale-flag detection (idempotently).

    New installs get this automatically via `up/1`. Existing Bandera installs
    should call it from a separate migration to add the table without touching
    the flags table:

        defmodule MyApp.Repo.Migrations.CreateBanderaUsage do
          use Ecto.Migration
          def up, do: Bandera.Ecto.Migrations.up_usage()
          def down, do: Bandera.Ecto.Migrations.down_usage()
        end

    Accepts `:usage_table` and `:prefix` (see the moduledoc). The table stores one
    row per flag — the timestamp it was last evaluated anywhere in the fleet.
    `Bandera.Usage` flushes to this table periodically (default every 10 minutes)
    and seeds ETS from it at startup.
    """
    @spec up_usage(keyword) :: :ok
    def up_usage(opts \\ []) do
      table_name = usage_table_name(opts)
      prefix = prefix(opts)

      create_if_not_exists table(table_name, primary_key: false, prefix: prefix) do
        add(:flag_name, :string, primary_key: true, null: false)
        add(:last_evaluated_at, :utc_datetime_usec, null: false)
      end

      :ok
    end

    @doc "Drops the usage table. Accepts `:usage_table` and `:prefix` (see the moduledoc)."
    @spec down_usage(keyword) :: :ok
    def down_usage(opts \\ []) do
      drop(table(usage_table_name(opts), prefix: prefix(opts)))
      :ok
    end

    @doc """
    Drops the flags table and the usage table. Call from the `down/0` of your own
    migration. Accepts `:table`, `:usage_table`, and `:prefix` (see the moduledoc).
    """
    @spec down(keyword) :: :ok
    def down(opts \\ []) do
      down_usage(opts)
      drop(table(table_name(opts), prefix: prefix(opts)))
      :ok
    end

    defp table_name(opts),
      do:
        Keyword.get_lazy(opts, :table, fn ->
          Bandera.Config.ecto_table_name(Bandera.Config.new())
        end)

    defp usage_table_name(opts) do
      Keyword.get_lazy(opts, :usage_table, fn ->
        Bandera.Config.new().persistence |> Keyword.get(:usage_table_name, "bandera_usage")
      end)
    end

    defp prefix(opts),
      do: Keyword.get_lazy(opts, :prefix, fn -> Bandera.Config.new().persistence[:prefix] end)

    defp qualified_table(opts) do
      case prefix(opts) do
        nil -> table_name(opts)
        prefix -> "#{prefix}.#{table_name(opts)}"
      end
    end
  end
end
