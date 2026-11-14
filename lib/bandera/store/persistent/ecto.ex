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
            ecto_table_name: "bandera_flags",
            # optional: the schema (PostgreSQL) or attached database (SQLite)
            # the tables live in; the repo's default when unset
            prefix: "my_schema"
          ]

    Run `Bandera.Ecto.Migrations.up/0` from a migration to create the table.

    ## Concurrency note

    Writing a percentage gate uses a transaction (delete the existing "percentage"
    row, insert the new one) rather than a database advisory lock. Single-writer
    configuration flows — the common case — are fully consistent. Under concurrent
    writes to the *same flag's* percentage gate, a colliding write returns
    `{:error, _}` (safe to retry); a rare interleaving of two different-ratio writes
    could momentarily leave two percentage rows. A future version may add advisory
    locking (as fun_with_flags does) if needed.

    ## Errors

    Unexpected database failures propagate as exceptions (let it crash — your repo's
    supervision tree handles recovery), consistent with the other persistence
    adapters. The percentage `put/2` additionally returns `{:error, reason}` when its
    transaction is rolled back.
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
      records = all(from(r in {table(), Record}, where: r.flag_name == ^name))
      {:ok, Serializer.deserialize_flag(flag_name, records)}
    end

    @impl Bandera.Store.Persistent
    def put(flag_name, %Gate{type: type} = gate)
        when type in [:percentage_of_time, :percentage_of_actors] do
      name = to_string(flag_name)
      row = Serializer.to_row(flag_name, gate)

      case repo().transaction(fn ->
             delete_all(
               from(r in {table(), Record},
                 where: r.flag_name == ^name and r.gate_type == "percentage"
               )
             )

             insert_all({table(), Record}, [row])
           end) do
        {:ok, _} -> get(flag_name)
        {:error, reason} -> {:error, reason}
      end
    end

    @impl Bandera.Store.Persistent
    def put(flag_name, %Gate{type: :boolean} = gate) do
      # A boolean gate always writes the `"_bandera_none"` sentinel target, so the
      # write itself is a plain conflict-target upsert — identical to the generic
      # `put/2` below and, crucially, atomic under concurrent toggles. The earlier
      # implementation did an unconditional `delete_all` + bare `insert_all`, which
      # is NOT atomic: two concurrent boolean writes to the same flag can both
      # delete, then both insert, and the second insert violates the
      # `(flag_name, gate_type, target)` unique index (Postgres 23505). The upsert
      # collapses that race into a harmless replace.
      #
      # We still clear any *legacy* FunWithFlags boolean rows (which used a
      # non-sentinel `target`, e.g. `"boolean"`), because those live at a different
      # target and so are invisible to the upsert's conflict target. This delete is
      # scoped to `target != sentinel`, so it never touches the row the upsert
      # manages and is therefore not part of the racy path. (The one-shot
      # `Bandera.Ecto.Migrations.fix_fun_with_flags_boolean_gates/0` migration
      # handles the same cleanup in bulk; this keeps runtime writes correct even if
      # that migration has not been run yet.)
      name = to_string(flag_name)
      sentinel = Serializer.serialize_target(nil)
      row = Serializer.to_row(flag_name, gate)

      delete_all(
        from(r in {table(), Record},
          where: r.flag_name == ^name and r.gate_type == "boolean" and r.target != ^sentinel
        )
      )

      insert_all({table(), Record}, [row],
        on_conflict: {:replace, [:enabled, :value]},
        conflict_target: [:flag_name, :gate_type, :target]
      )

      get(flag_name)
    end

    @impl Bandera.Store.Persistent
    def put(flag_name, %Gate{} = gate) do
      row = Serializer.to_row(flag_name, gate)

      insert_all({table(), Record}, [row],
        on_conflict: {:replace, [:enabled, :value]},
        conflict_target: [:flag_name, :gate_type, :target]
      )

      get(flag_name)
    end

    @impl Bandera.Store.Persistent
    def delete(flag_name, %Gate{type: type})
        when type in [:percentage_of_time, :percentage_of_actors] do
      name = to_string(flag_name)

      delete_all(
        from(r in {table(), Record}, where: r.flag_name == ^name and r.gate_type == "percentage")
      )

      get(flag_name)
    end

    @impl Bandera.Store.Persistent
    def delete(flag_name, %Gate{} = gate) do
      name = to_string(flag_name)
      gate_type = to_string(gate.type)
      target = Serializer.serialize_target(gate.for)

      delete_all(
        from(r in {table(), Record},
          where: r.flag_name == ^name and r.gate_type == ^gate_type and r.target == ^target
        )
      )

      get(flag_name)
    end

    @impl Bandera.Store.Persistent
    def delete(flag_name) do
      name = to_string(flag_name)
      delete_all(from(r in {table(), Record}, where: r.flag_name == ^name))
      {:ok, Flag.new(flag_name, [])}
    end

    @impl Bandera.Store.Persistent
    def all_flags do
      flags =
        from(r in {table(), Record})
        |> all()
        |> Enum.group_by(& &1.flag_name)
        |> Enum.map(fn {name, records} -> Serializer.deserialize_flag(name, records) end)

      {:ok, flags}
    end

    @impl Bandera.Store.Persistent
    def all_flag_names do
      names =
        from(r in {table(), Record}, select: r.flag_name, distinct: true)
        |> all()
        |> Enum.map(&String.to_atom/1)

      {:ok, names}
    end

    defp repo, do: Keyword.fetch!(Config.persistence(), :repo)

    # Every query and insert goes through these, so the configured `:prefix`
    # (the schema the table lives in) reaches each of them.
    defp all(query), do: repo().all(query, Config.ecto_repo_opts())
    defp delete_all(query), do: repo().delete_all(query, Config.ecto_repo_opts())

    defp insert_all(source, rows, opts \\ []),
      do: repo().insert_all(source, rows, opts ++ Config.ecto_repo_opts())

    defp table, do: Config.ecto_table_name()
  end
end
