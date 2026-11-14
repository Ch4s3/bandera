if Code.ensure_loaded?(Ecto.Migration) do
  defmodule Bandera.Ecto.Migrations do
    @moduledoc """
    Helpers for creating Bandera's tables. Call from your own migration:

        defmodule MyApp.Repo.Migrations.CreateBandera do
          use Ecto.Migration
          def up, do: Bandera.Ecto.Migrations.up()
          def down, do: Bandera.Ecto.Migrations.down()
        end

    `up/0` creates both the flags table and the usage table (for stale-flag
    detection). Existing installs that already have the flags table can add just
    the usage table via `up_usage/0` from a new migration.

    Table names are read at runtime from `config :bandera, persistence: [...]`
    (`ecto_table_name`, default `"bandera_flags"`; `usage_table_name`, default
    `"bandera_usage"`), so they are never fixed at compile time. With
    `prefix: "my_schema"` the tables are created in that schema (PostgreSQL) or
    attached database (SQLite), where the adapter then reads and writes them.
    """

    import Ecto.Migration

    @doc """
    Creates the flags table (and its index) plus the usage table, idempotently.

    Call from the `up/0` of your own migration. Table names are read at runtime
    from `Bandera.Config`. New installs get everything in one migration; uses
    `create_if_not_exists` throughout so it is safe on all SQL backends.
    """
    @spec up() :: :ok
    def up do
      table_name = Bandera.Config.ecto_table_name()

      create_if_not_exists table(table_name, prefix: schema_prefix()) do
        add(:flag_name, :string, null: false)
        add(:gate_type, :string, null: false)
        add(:target, :string, null: false)
        add(:enabled, :boolean, null: false)
        add(:value, :string)
      end

      create_if_not_exists(
        unique_index(table_name, [:flag_name, :gate_type, :target],
          name: :"#{table_name}_flag_name_gate_target_idx",
          prefix: schema_prefix()
        )
      )

      up_usage()

      :ok
    end

    @doc """
    Add the schema-v2 `value` column to an existing flags table.

    Call once from the `up/0` of a versioned migration in an existing install:

        defmodule MyApp.Repo.Migrations.UpgradeBanderaV2 do
          use Ecto.Migration
          def up, do: Bandera.Ecto.Migrations.upgrade_v2()
        end

    Uses a plain `add/2` (not `add_if_not_exists/2`) so it works on adapters such as
    SQLite3 that reject conditional column additions; migration versioning ensures it
    runs only once.
    """
    @spec upgrade_v2() :: :ok
    def upgrade_v2 do
      alter table(Bandera.Config.ecto_table_name(), prefix: schema_prefix()) do
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

    Safe to run on a database that has already been fully migrated — it will find
    nothing to change. Not reversible (`down` should be a no-op).
    """
    @spec fix_fun_with_flags_boolean_gates() :: :ok
    def fix_fun_with_flags_boolean_gates do
      table = qualified(Bandera.Config.ecto_table_name())
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

    New installs get this automatically via `up/0`. Existing Bandera installs
    should call it from a separate migration to add the table without touching
    the flags table:

        defmodule MyApp.Repo.Migrations.CreateBanderaUsage do
          use Ecto.Migration
          def up, do: Bandera.Ecto.Migrations.up_usage()
          def down, do: Bandera.Ecto.Migrations.down_usage()
        end

    The table stores one row per flag — the timestamp it was last evaluated
    anywhere in the fleet. `Bandera.Usage` flushes to this table periodically
    (default every 10 minutes) and seeds ETS from it at startup.
    """
    @spec up_usage() :: :ok
    def up_usage do
      table_name = usage_table_name()

      create_if_not_exists table(table_name, primary_key: false, prefix: schema_prefix()) do
        add(:flag_name, :string, primary_key: true, null: false)
        add(:last_evaluated_at, :utc_datetime_usec, null: false)
      end

      :ok
    end

    @doc "Drops the usage table."
    @spec down_usage() :: :ok
    def down_usage do
      drop(table(usage_table_name(), prefix: schema_prefix()))
      :ok
    end

    @doc """
    Drops the flags table and the usage table. Call from the `down/0` of your
    own migration.
    """
    @spec down() :: :ok
    def down do
      down_usage()
      drop(table(Bandera.Config.ecto_table_name(), prefix: schema_prefix()))
      :ok
    end

    defp usage_table_name do
      :bandera
      |> Application.get_env(:persistence, [])
      |> Keyword.get(:usage_table_name, "bandera_usage")
    end

    # The schema the tables live in (`persistence: [prefix: ...]`); nil is the
    # repo's default.
    defp schema_prefix, do: Bandera.Config.ecto_prefix()

    defp qualified(table) do
      case schema_prefix() do
        nil -> table
        prefix -> "#{prefix}.#{table}"
      end
    end
  end
end
