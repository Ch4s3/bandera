if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Bandera.Store.Persistent.Ecto.Record do
    @moduledoc false
    # Ecto schema for a single flag-gate row. The `schema "bandera_flags"` source is
    # only a placeholder/default; the adapter always overrides it at query time via
    # `{Bandera.Config.ecto_table_name(), Record}`, so the table name stays runtime
    # configured (no compile-time table config). The schema exists purely to give
    # Ecto the field types needed for portable casting (e.g. booleans) across SQL
    # backends.
    use Ecto.Schema

    @primary_key {:id, :id, autogenerate: true}
    schema "bandera_flags" do
      field(:flag_name, :string)
      field(:gate_type, :string)
      field(:target, :string)
      field(:enabled, :boolean)
      field(:value, :string)
    end
  end
end
