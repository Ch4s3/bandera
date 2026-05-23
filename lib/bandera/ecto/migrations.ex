if Code.ensure_loaded?(Ecto.Migration) do
  defmodule Bandera.Ecto.Migrations do
    @moduledoc """
    Helpers for creating the Bandera flags table. Call from your own migration:

        defmodule MyApp.Repo.Migrations.CreateBanderaFlags do
          use Ecto.Migration
          def up, do: Bandera.Ecto.Migrations.up()
          def down, do: Bandera.Ecto.Migrations.down()
        end

    The table name is read at runtime from `config :bandera, persistence: [ecto_table_name: ...]`
    (default `"bandera_flags"`), so it is never fixed at compile time.
    """

    import Ecto.Migration

    @doc """
    Creates the flags table and its unique index (idempotently).

    Call from the `up/0` of your own migration. The table name is read at runtime
    from `Bandera.Config.ecto_table_name/0`.
    """
    @spec up() :: :ok
    def up do
      table_name = Bandera.Config.ecto_table_name()

      create_if_not_exists table(table_name) do
        add(:flag_name, :string, null: false)
        add(:gate_type, :string, null: false)
        add(:target, :string, null: false)
        add(:enabled, :boolean, null: false)
        add(:value, :string)
      end

      create_if_not_exists(
        unique_index(table_name, [:flag_name, :gate_type, :target],
          name: :"#{table_name}_flag_name_gate_target_idx"
        )
      )

      :ok
    end

    @doc "Add the schema-v2 `value` column to an existing flags table."
    @spec upgrade_v2() :: :ok
    def upgrade_v2 do
      alter table(Bandera.Config.ecto_table_name()) do
        add_if_not_exists(:value, :string)
      end

      :ok
    end

    @doc "Drops the flags table. Call from the `down/0` of your own migration."
    @spec down() :: :ok
    def down do
      drop(table(Bandera.Config.ecto_table_name()))
      :ok
    end
  end
end
