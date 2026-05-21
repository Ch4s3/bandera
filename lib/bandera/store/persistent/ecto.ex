if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Bandera.Store.Persistent.Ecto do
    @moduledoc """
    SQL persistence adapter. The repo and table name are read from
    `Bandera.Config` at RUNTIME and queries bind the table via Ecto's
    `{table_name, Record}` source form, so nothing about the table is fixed at
    compile time. The `Record` schema supplies field types so values (e.g.
    booleans) cast portably across SQL backends.

    Configure:

        config :bandera,
          persistence: [
            adapter: Bandera.Store.Persistent.Ecto,
            repo: MyApp.Repo,
            ecto_table_name: "bandera_flags"
          ]

    Run `Bandera.Ecto.Migrations.up/0` from a migration to create the table.
    """

    @behaviour Bandera.Store.Persistent

    import Ecto.Query

    alias Bandera.Config
    alias Bandera.Flag
    alias Bandera.Gate
    alias Bandera.Store.Persistent.Ecto.Record
    alias Bandera.Store.Persistent.Ecto.Serializer

    @impl Bandera.Store.Persistent
    def get(flag_name) do
      name = to_string(flag_name)
      records = repo().all(from(r in {table(), Record}, where: r.flag_name == ^name))
      {:ok, Serializer.deserialize_flag(flag_name, records)}
    end

    @impl Bandera.Store.Persistent
    def put(flag_name, %Gate{type: type} = gate)
        when type in [:percentage_of_time, :percentage_of_actors] do
      name = to_string(flag_name)
      row = Serializer.to_row(flag_name, gate)

      repo().transaction(fn ->
        repo().delete_all(
          from(r in {table(), Record},
            where: r.flag_name == ^name and r.gate_type == "percentage"
          )
        )

        repo().insert_all({table(), Record}, [row])
      end)

      get(flag_name)
    end

    @impl Bandera.Store.Persistent
    def put(flag_name, %Gate{} = gate) do
      row = Serializer.to_row(flag_name, gate)

      repo().insert_all({table(), Record}, [row],
        on_conflict: {:replace, [:enabled]},
        conflict_target: [:flag_name, :gate_type, :target]
      )

      get(flag_name)
    end

    @impl Bandera.Store.Persistent
    def delete(flag_name, %Gate{type: type})
        when type in [:percentage_of_time, :percentage_of_actors] do
      name = to_string(flag_name)

      repo().delete_all(
        from(r in {table(), Record}, where: r.flag_name == ^name and r.gate_type == "percentage")
      )

      get(flag_name)
    end

    @impl Bandera.Store.Persistent
    def delete(flag_name, %Gate{} = gate) do
      name = to_string(flag_name)
      gate_type = to_string(gate.type)
      target = Serializer.serialize_target(gate.for)

      repo().delete_all(
        from(r in {table(), Record},
          where: r.flag_name == ^name and r.gate_type == ^gate_type and r.target == ^target
        )
      )

      get(flag_name)
    end

    @impl Bandera.Store.Persistent
    def delete(flag_name) do
      name = to_string(flag_name)
      repo().delete_all(from(r in {table(), Record}, where: r.flag_name == ^name))
      {:ok, Flag.new(flag_name, [])}
    end

    @impl Bandera.Store.Persistent
    def all_flags do
      flags =
        from(r in {table(), Record})
        |> repo().all()
        |> Enum.group_by(& &1.flag_name)
        |> Enum.map(fn {name, records} -> Serializer.deserialize_flag(name, records) end)

      {:ok, flags}
    end

    @impl Bandera.Store.Persistent
    def all_flag_names do
      names =
        from(r in {table(), Record}, select: r.flag_name, distinct: true)
        |> repo().all()
        |> Enum.map(&String.to_atom/1)

      {:ok, names}
    end

    defp repo, do: Keyword.fetch!(Config.persistence(), :repo)
    defp table, do: Config.ecto_table_name()
  end
end
