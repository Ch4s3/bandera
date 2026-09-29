if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Bandera.Usage.Ecto do
    @moduledoc """
    Durable DB backend for `Bandera.Usage`.

    Called by `Bandera.Usage` to seed ETS once the Repo is up, periodically merge
    other nodes' persisted history, and flush the whole ETS table back so
    evaluation history survives process restarts and pod recycling.

    Every flush keeps the greater of the existing and incoming timestamp, so a
    lagging pod cannot regress shared history. Trackers also periodically merge
    the DB back into ETS so evaluations observed by other pods become visible
    locally.

    The table is separate from the flags table — create it via
    `Bandera.Ecto.Migrations.up_usage/0`. Its name (`usage_table_name`, default
    `"bandera_usage"`), repo, and `prefix` come from the instance's
    `persistence:` config.

    Only active when `persistence: [adapter: Bandera.Store.Persistent.Ecto]`
    is configured. DB errors are returned without raising so ETS-only operation
    continues. Load errors keep `Bandera.Usage` unready while it retries
    independently of the flush interval.
    """

    import Ecto.Query

    alias Bandera.Config
    alias Bandera.Usage.Record

    @doc """
    Loads all rows from `conf`'s DB usage table into `ets_table`, keeping whichever
    timestamp is newer. Called at startup and before periodic flushes. Pass
    `return_errors: true` when the caller needs to distinguish a failed load
    from a successful no-op.
    """
    @spec load_into_ets(Config.t(), atom, keyword) :: :ok | {:error, term}
    def load_into_ets(%Config{} = conf, ets_table, opts) do
      rows = repo(conf).all(from(r in {table_name(conf), Record}), repo_opts(conf))

      for %Record{flag_name: name, last_evaluated_at: db_at} <- rows do
        atom = String.to_atom(name)

        case :ets.lookup(ets_table, atom) do
          [{^atom, mem_at}] ->
            if DateTime.compare(db_at, mem_at) == :gt,
              do: :ets.insert(ets_table, {atom, db_at})

          [] ->
            :ets.insert(ets_table, {atom, db_at})
        end
      end

      :ok
    rescue
      error -> if Keyword.get(opts, :return_errors, false), do: {:error, error}, else: :ok
    end

    @doc "Default-instance form of `load_into_ets/3` (backward compatibility)."
    @spec load_into_ets(atom) :: :ok
    @spec load_into_ets(atom, keyword) :: :ok | {:error, term}
    def load_into_ets(ets_table, opts \\ []) when is_atom(ets_table),
      do: load_into_ets(Config.get(), ets_table, opts)

    @doc """
    Upserts every `{flag_name, datetime}` pair in `ets_table` into `conf`'s DB
    usage table, keeping the greater of the persisted and incoming timestamps.
    """
    @spec flush_all(Config.t(), atom) :: :ok
    def flush_all(%Config{} = conf, ets_table) do
      rows =
        ets_table
        |> :ets.tab2list()
        |> Enum.map(fn {name, at} ->
          %{flag_name: to_string(name), last_evaluated_at: at}
        end)

      unless rows == [] do
        conflict_query =
          from(usage in {table_name(conf), Record},
            update: [
              set: [
                last_evaluated_at:
                  fragment(
                    "CASE WHEN EXCLUDED.last_evaluated_at > ? THEN EXCLUDED.last_evaluated_at ELSE ? END",
                    usage.last_evaluated_at,
                    usage.last_evaluated_at
                  )
              ]
            ]
          )

        repo(conf).insert_all(
          {table_name(conf), Record},
          rows,
          [on_conflict: conflict_query, conflict_target: [:flag_name]] ++ repo_opts(conf)
        )
      end

      :ok
    rescue
      _error -> :ok
    end

    @doc "Default-instance form of `flush_all/2` (backward compatibility)."
    @spec flush_all(atom) :: :ok
    def flush_all(ets_table) when is_atom(ets_table), do: flush_all(Config.get(), ets_table)

    @doc false
    # The usage table `conf` flushes into; two trackers may not share one. `nil`
    # when no repo is configured yet (nothing to claim).
    @spec storage_id(Config.t()) :: term | nil
    def storage_id(%Config{} = conf) do
      case Keyword.get(conf.persistence, :repo) do
        nil ->
          nil

        repo ->
          {__MODULE__, Bandera.Store.Persistent.Ecto.database_location(repo), prefix(conf),
           table_name(conf)}
      end
    end

    defp repo(conf), do: Keyword.fetch!(conf.persistence, :repo)

    defp table_name(conf),
      do: Keyword.get(conf.persistence, :usage_table_name, "bandera_usage")

    defp prefix(conf), do: Keyword.get(conf.persistence, :prefix)

    defp repo_opts(conf) do
      case prefix(conf) do
        nil -> []
        prefix -> [prefix: prefix]
      end
    end
  end
end
