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

    @spec up() :: :ok
    def up do
      table_name = Bandera.Config.ecto_table_name()

      create_if_not_exists table(table_name) do
        add(:flag_name, :string, null: false)
        add(:gate_type, :string, null: false)
        add(:target, :string, null: false)
        add(:enabled, :boolean, null: false)
      end

      create_if_not_exists(
        unique_index(table_name, [:flag_name, :gate_type, :target],
          name: :"#{table_name}_flag_name_gate_target_idx"
        )
      )

      :ok
    end

    @spec down() :: :ok
    def down do
      drop(table(Bandera.Config.ecto_table_name()))
      :ok
    end
  end
end
