if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Bandera.Store.Persistent.Ecto do
    @moduledoc """
    SQL persistence adapter. The repo, table name, and schema prefix are read from
    the calling instance's `%Bandera.Config{}` at RUNTIME and queries bind the
    table via Ecto's `{table_name, Record}` source form, so nothing about the
    table is fixed at compile time. The `Record` schema supplies field types so
    values (e.g. booleans) cast portably across SQL backends.

    Configure:

        config :bandera,
          persistence: [
            adapter: Bandera.Store.Persistent.Ecto,
            repo: MyApp.Repo,
            ecto_table_name: "bandera_flags"
          ]

    Run `Bandera.Ecto.Migrations.up/0` from a migration to create the table.

    ## Multiple instances

    Each instance gets its own storage — never share one between two running
    instances. Give each instance either its own table (`ecto_table_name`) on a
    shared repo, or its own Postgres schema via `prefix:` (below), or both. The
    adapter implements `c:Bandera.Store.Persistent.storage_id/1`, so an instance
    whose database, prefix, and table all match a running instance refuses to
    start. The database is identified by the repo's host, port, and database
    name, so two repo modules pointed at the same database count as one.

    ## Postgres schema prefix

    `persistence: [prefix: "tenant_a"]` scopes every query this adapter runs to
    that Postgres schema (via Ecto's `:prefix` option on every repo call). The
    schema itself is not created by this adapter or by `Bandera.Ecto.Migrations`
    — create it yourself before running migrations. Leaving `prefix` unset (the
    default) uses the repo's default schema, exactly as before this option
    existed. SQLite has no schemas: leave `prefix` unset there (ecto_sqlite3 raises
    on any query with a prefix).

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
    adapters. The percentage `put/3` additionally returns `{:error, reason}` when its
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
    def get(%Config{} = conf, flag_name) do
      name = to_string(flag_name)

      records =
        repo(conf).all(
          from(r in {table(conf), Record}, where: r.flag_name == ^name),
          repo_opts(conf)
        )

      {:ok, Serializer.deserialize_flag(flag_name, records)}
    end

    @impl Bandera.Store.Persistent
    def put(%Config{} = conf, flag_name, %Gate{type: type} = gate)
        when type in [:percentage_of_time, :percentage_of_actors] do
      name = to_string(flag_name)
      row = Serializer.to_row(flag_name, gate)

      case repo(conf).transaction(
             fn ->
               repo(conf).delete_all(
                 from(r in {table(conf), Record},
                   where: r.flag_name == ^name and r.gate_type == "percentage"
                 ),
                 repo_opts(conf)
               )

               repo(conf).insert_all({table(conf), Record}, [row], repo_opts(conf))
             end,
             repo_opts(conf)
           ) do
        {:ok, _} -> get(conf, flag_name)
        {:error, reason} -> {:error, reason}
      end
    end

    @impl Bandera.Store.Persistent
    def put(%Config{} = conf, flag_name, %Gate{type: :boolean} = gate) do
      # A boolean gate always writes the `"_bandera_none"` sentinel target, so the
      # write itself is a plain conflict-target upsert — identical to the generic
      # `put/3` below and, crucially, atomic under concurrent toggles. The earlier
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
      # `Bandera.Ecto.Migrations.fix_fun_with_flags_boolean_gates/1` migration
      # handles the same cleanup in bulk; this keeps runtime writes correct even if
      # that migration has not been run yet.)
      name = to_string(flag_name)
      sentinel = Serializer.serialize_target(nil)
      row = Serializer.to_row(flag_name, gate)

      repo(conf).delete_all(
        from(r in {table(conf), Record},
          where: r.flag_name == ^name and r.gate_type == "boolean" and r.target != ^sentinel
        ),
        repo_opts(conf)
      )

      repo(conf).insert_all(
        {table(conf), Record},
        [row],
        [
          on_conflict: {:replace, [:enabled, :value]},
          conflict_target: [:flag_name, :gate_type, :target]
        ] ++
          repo_opts(conf)
      )

      get(conf, flag_name)
    end

    @impl Bandera.Store.Persistent
    def put(%Config{} = conf, flag_name, %Gate{} = gate) do
      row = Serializer.to_row(flag_name, gate)

      repo(conf).insert_all(
        {table(conf), Record},
        [row],
        [
          on_conflict: {:replace, [:enabled, :value]},
          conflict_target: [:flag_name, :gate_type, :target]
        ] ++
          repo_opts(conf)
      )

      get(conf, flag_name)
    end

    @impl Bandera.Store.Persistent
    def delete(%Config{} = conf, flag_name, %Gate{type: type})
        when type in [:percentage_of_time, :percentage_of_actors] do
      name = to_string(flag_name)

      repo(conf).delete_all(
        from(r in {table(conf), Record},
          where: r.flag_name == ^name and r.gate_type == "percentage"
        ),
        repo_opts(conf)
      )

      get(conf, flag_name)
    end

    @impl Bandera.Store.Persistent
    def delete(%Config{} = conf, flag_name, %Gate{} = gate) do
      name = to_string(flag_name)
      gate_type = to_string(gate.type)
      target = Serializer.serialize_target(gate.for)

      repo(conf).delete_all(
        from(r in {table(conf), Record},
          where: r.flag_name == ^name and r.gate_type == ^gate_type and r.target == ^target
        ),
        repo_opts(conf)
      )

      get(conf, flag_name)
    end

    @impl Bandera.Store.Persistent
    def delete(%Config{} = conf, flag_name) do
      name = to_string(flag_name)

      repo(conf).delete_all(
        from(r in {table(conf), Record}, where: r.flag_name == ^name),
        repo_opts(conf)
      )

      {:ok, Flag.new(flag_name, [])}
    end

    def delete(flag_name, %Gate{} = gate) when is_atom(flag_name),
      do: delete(Config.get(), flag_name, gate)

    @impl Bandera.Store.Persistent
    def all_flags(%Config{} = conf) do
      flags =
        from(r in {table(conf), Record})
        |> repo(conf).all(repo_opts(conf))
        |> Enum.group_by(& &1.flag_name)
        |> Enum.map(fn {name, records} -> Serializer.deserialize_flag(name, records) end)

      {:ok, flags}
    end

    @impl Bandera.Store.Persistent
    def all_flag_names(%Config{} = conf) do
      names =
        from(r in {table(conf), Record}, select: r.flag_name, distinct: true)
        |> repo(conf).all(repo_opts(conf))
        |> Enum.map(&String.to_atom/1)

      {:ok, names}
    end

    @doc false
    # The database, schema, and table `conf` points at; two running instances may
    # not share one (see `Bandera.Store.Persistent.storage_id/1`).
    @impl Bandera.Store.Persistent
    # No repo configured yet (it may be supplied later via `reload_config`): there
    # is nothing to claim, and the instance must still start as it always has.
    def storage_id(%Config{} = conf) do
      case Keyword.get(conf.persistence, :repo) do
        nil -> nil
        repo -> {__MODULE__, database_location(repo), prefix(conf), table(conf)}
      end
    end

    @doc false
    # The physical database `repo` points at, so that two repo modules configured
    # against the same database — e.g. a host app's repo and an embedded app's —
    # are recognized as the same storage. Falls back to the repo module itself
    # when its runtime config can't be read or names no database.
    @spec database_location(module) :: {String.t(), String.t(), String.t()} | module
    def database_location(repo) do
      config = repo.config()
      host = config[:hostname] || config[:socket_dir] || config[:socket] || ""

      case to_string(config[:database] || "") do
        "" -> repo
        database -> {String.downcase(to_string(host)), to_string(config[:port] || ""), database}
      end
    rescue
      _ -> repo
    end

    defp repo(conf), do: Keyword.fetch!(conf.persistence, :repo)
    defp table(conf), do: Config.ecto_table_name(conf)
    defp prefix(conf), do: Keyword.get(conf.persistence, :prefix)

    defp repo_opts(conf) do
      case prefix(conf) do
        nil -> []
        prefix -> [prefix: prefix]
      end
    end

    # ---- default-instance forms (backward compatibility) ----
    # The pre-instance arities, acting on the default instance (the
    # `delete(flag_name, gate)` form sits with the `delete/2` callback above).

    @doc false

    @spec get(atom) :: {:ok, Bandera.Flag.t()} | {:error, term}
    def get(flag_name) when is_atom(flag_name), do: get(Config.get(), flag_name)

    @doc false

    @spec put(atom, Bandera.Gate.t()) :: {:ok, Bandera.Flag.t()} | {:error, term}
    def put(flag_name, %Gate{} = gate) when is_atom(flag_name),
      do: put(Config.get(), flag_name, gate)

    @doc false

    @spec delete(atom) :: {:ok, Bandera.Flag.t()} | {:error, term}
    def delete(flag_name) when is_atom(flag_name), do: delete(Config.get(), flag_name)

    @doc false

    @spec all_flags() :: {:ok, [Bandera.Flag.t()]} | {:error, term}
    def all_flags, do: all_flags(Config.get())

    @doc false

    @spec all_flag_names() :: {:ok, [atom]} | {:error, term}
    def all_flag_names, do: all_flag_names(Config.get())
  end
end
