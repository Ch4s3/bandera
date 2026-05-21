defmodule Bandera.TestRepo.Migration do
  use Ecto.Migration

  @spec up() :: :ok
  def up, do: Bandera.Ecto.Migrations.up()

  @spec down() :: :ok
  def down, do: Bandera.Ecto.Migrations.down()
end
