defmodule Bandera.TestRepo.Migration do
  use Ecto.Migration

  # `bandera_flags_2` mirrors `bandera_flags` (same columns and unique index) so
  # multi-instance isolation tests can point a second instance at a distinct
  # table on the same repo.
  @second_table "bandera_flags_2"

  @spec up() :: :ok
  def up do
    Bandera.Ecto.Migrations.up()
    Bandera.Ecto.Migrations.up(table: @second_table)
    :ok
  end

  @spec down() :: :ok
  def down do
    # Drop the second table directly (not via `Migrations.down/1`, which also
    # drops the usage table shared with the first `up/0` call above).
    drop(table(@second_table))
    Bandera.Ecto.Migrations.down()
    :ok
  end
end
