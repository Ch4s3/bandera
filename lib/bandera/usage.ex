defmodule Bandera.Usage do
  @moduledoc """
  Optional last-evaluated tracker. Attaches to `[:bandera, :enabled?]` and
  `[:bandera, :variant]` telemetry events and records, in ETS, the last time
  each flag was checked — the signal for `Bandera.stale_flags/1`.

  When the Ecto persistence adapter is configured, evaluation history is also
  persisted to a `bandera_usage` DB table so it survives restarts and pod
  recycling. The DB is seeded into ETS once the Repo is available, with a short
  independent retry while the Repo is still starting. Every `flush_interval`
  seconds (default 600 / 10 minutes), the tracker merges persisted history into
  ETS and flushes the whole ETS table back with monotonic timestamps. This keeps
  multiple nodes convergent without adding work to the evaluation hot path.

  Just add it to your supervision tree — it attaches its own telemetry handler in
  `init/1` and detaches on shutdown, so the handler's lifecycle follows the
  process (a crash-and-restart re-attaches against a fresh ETS table):

      children = [
        ...,
        Bandera.Usage
      ]

  Create the usage table with `Bandera.Ecto.Migrations.up_usage/0` from a
  migration before enabling DB persistence.

  ## Instances

  A tracker belongs to one instance and only records that instance's
  evaluations. `Bandera.Usage` alone tracks the default instance; track a named
  instance by starting another tracker after it:

      children = [MyApp.Flags, {Bandera.Usage, instance: MyApp.Flags}]

  With the Ecto adapter, each tracker needs its own usage table (set
  `persistence: [usage_table_name: ...]` for the instance); a tracker whose table
  is already used by another running tracker refuses to start. Options:
  `:instance`, `:flush_interval`, `:load_retry_interval`, and
  `:load_retry_max_interval` (seconds), the latter three defaulting to the
  instance's `usage:` settings.
  """
  use GenServer

  alias Bandera.Config

  @default_instance Bandera
  @events [[:bandera, :enabled?], [:bandera, :variant]]
  @default_flush_interval 600
  @default_load_retry_interval 1
  @default_load_retry_max_interval 30

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc false
  @spec child_spec(keyword) :: Supervisor.child_spec()
  def child_spec(opts) do
    id =
      case Keyword.get(opts, :instance, @default_instance) do
        @default_instance -> __MODULE__
        instance -> {__MODULE__, instance}
      end

    %{id: id, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Starts the Usage tracker (for `opts[:instance]`, default `Bandera`). Add to your supervision tree."
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts \\ []) do
    conf = opts |> Keyword.get(:instance, @default_instance) |> Config.get()
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, conf.usage_server))
  end

  @doc """
  Registers the telemetry handler for `instance` (default `Bandera`).

  Called automatically from the GenServer's `init/1`; you do not need to call it
  yourself. Exposed mainly for tests.
  """
  @spec attach(atom) :: :ok | {:error, :already_exists}
  def attach(instance \\ @default_instance) do
    config = %{instance: instance, table: Config.get(instance).usage_server}
    :telemetry.attach_many(handler_id(instance), @events, &__MODULE__.handle_event/4, config)
  end

  @doc "Unregisters the telemetry handler for `instance`. Called automatically on shutdown."
  @spec detach(atom) :: :ok | {:error, :not_found}
  def detach(instance \\ @default_instance), do: :telemetry.detach(handler_id(instance))

  @doc """
  Returns the last UTC `DateTime` `flag_name` was evaluated, or `nil` if never seen.

  `last_evaluated/1` reads the default instance's tracker; `last_evaluated/2`
  takes an instance name (or its `%Bandera.Config{}`) first. Raises
  `ArgumentError` if that tracker is not running.
  """
  @spec last_evaluated(atom) :: DateTime.t() | nil
  def last_evaluated(flag_name) when is_atom(flag_name),
    do: last_evaluated(@default_instance, flag_name)

  @spec last_evaluated(atom | Config.t(), atom) :: DateTime.t() | nil
  def last_evaluated(%Config{usage_server: table}, flag_name) do
    case :ets.lookup(table, flag_name) do
      [{^flag_name, at}] -> at
      [] -> nil
    end
  end

  def last_evaluated(instance, flag_name) when is_atom(instance),
    do: last_evaluated(Config.get(instance), flag_name)

  @doc "Immediately flushes `instance`'s ETS to the DB. Useful in tests and clean shutdowns."
  @spec flush(atom) :: :ok
  def flush(instance \\ @default_instance), do: GenServer.call(server(instance), :flush)

  @doc """
  Returns whether `instance`'s persisted usage history has been loaded.

  Trackers without Ecto persistence are ready immediately. This call requires
  the Usage process to be running.
  """
  @spec ready?(atom) :: boolean
  def ready?(instance \\ @default_instance), do: GenServer.call(server(instance), :ready?)

  # ── Telemetry handler (called from any process) ────────────────────────────

  @doc false
  @spec handle_event(list, map, map, map) :: :ok
  def handle_event(
        [:bandera, _event],
        _measurements,
        %{flag_name: flag_name} = metadata,
        %{instance: instance, table: table}
      ) do
    # Hot path: one comparison and at most one ETS write. Every tracker sees every
    # instance's events, so record only our own. Never raise — :telemetry would
    # detach us on error, silently stopping tracking.
    if Map.get(metadata, :instance, @default_instance) == instance do
      :ets.insert(table, {flag_name, DateTime.utc_now()})
    end

    :ok
  rescue
    _ -> :ok
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    # Trap exits so terminate/2 runs on supervisor shutdown — a final flush plus
    # detach, keeping the handler's lifecycle tied to this process.
    Process.flag(:trap_exit, true)

    instance = Keyword.get(opts, :instance, @default_instance)
    conf = Config.get(instance)

    case claim_usage_table(conf) do
      :ok ->
        :ets.new(conf.usage_server, [:named_table, :public, :set, write_concurrency: true])

        # Attach the telemetry handler here (not from the host application) so that a
        # crash-and-restart re-registers it against the fresh ETS table this init
        # creates. A stale handler from a prior incarnation is detached first so the
        # re-attach always succeeds.
        detach(instance)
        attach(instance)

        usage = Config.new(conf.start_opts).usage
        flush_interval = setting(opts, usage, :flush_interval, @default_flush_interval)

        load_retry_interval =
          setting(opts, usage, :load_retry_interval, @default_load_retry_interval)

        load_retry_max_interval =
          setting(opts, usage, :load_retry_max_interval, @default_load_retry_max_interval)

        state = %{
          instance: instance,
          table: conf.usage_server,
          flush_interval: flush_interval,
          load_retry_interval: min(load_retry_interval, load_retry_max_interval),
          load_retry_max_interval: load_retry_max_interval,
          loaded?: not ecto_adapter?(conf)
        }

        state = load_from_db(state)
        state = schedule_load_retry(state)
        schedule_flush(flush_interval)
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Best-effort: detach the handler (its ETS table is about to vanish) and flush
    # what we have so a clean shutdown doesn't lose up to a full interval of data.
    detach(state.instance)
    flush_to_db(state)
    :ok
  rescue
    _ -> :ok
  end

  @impl true
  def handle_call(:flush, _from, state) do
    state = load_from_db(state)
    flush_to_db(state)
    {:reply, :ok, state}
  end

  def handle_call(:ready?, _from, state), do: {:reply, state.loaded?, state}

  @impl true
  def handle_info(:flush, state) do
    # Merge other nodes' persisted evaluations before flushing this node's
    # in-memory values. Both directions keep the newer timestamp.
    state = load_from_db(state)
    flush_to_db(state)
    schedule_flush(state.flush_interval)
    {:noreply, state}
  end

  def handle_info(:load_from_db, state) do
    state = load_from_db(state)
    state = schedule_load_retry(state)
    {:noreply, state}
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  # The default instance keeps the handler id it has always had.
  defp handler_id(@default_instance), do: {__MODULE__, :usage}
  defp handler_id(instance), do: {__MODULE__, instance}

  defp server(instance), do: Config.get(instance).usage_server

  # Two trackers flushing into one usage table would mix their instances' history.
  defp claim_usage_table(conf) do
    with true <- ecto_adapter?(conf),
         id when not is_nil(id) <- Bandera.Usage.Ecto.storage_id(conf) do
      Bandera.Instance.claim_storage(id, conf.name)
    else
      _ -> :ok
    end
  end

  # `usage:` settings are read when the tracker starts (as they always were for
  # `config :bandera, usage: ...`), not from the possibly older stored config.
  defp setting(opts, usage, key, default) do
    Keyword.get_lazy(opts, key, fn -> Keyword.get(usage, key, default) end)
  end

  # The instance's config is re-read on every DB interaction (not cached in the
  # state) so a `Bandera.reload_config/1` takes effect. If the instance is briefly
  # not running (e.g. it is restarting), skip this round rather than crash.
  defp current_conf(state) do
    {:ok, Config.get(state.instance)}
  rescue
    ArgumentError -> :error
  end

  defp schedule_flush(interval),
    do: Process.send_after(self(), :flush, interval * 1_000)

  defp schedule_load_retry(
         %{
           loaded?: false,
           load_retry_interval: interval,
           load_retry_max_interval: max_interval
         } = state
       ) do
    Process.send_after(self(), :load_from_db, interval * 1_000)
    %{state | load_retry_interval: min(interval * 2, max_interval)}
  end

  defp schedule_load_retry(state), do: state

  defp ecto_adapter?(conf) do
    conf.persistence_adapter == Bandera.Store.Persistent.Ecto and
      Code.ensure_loaded?(Bandera.Usage.Ecto)
  rescue
    _ -> false
  end

  defp db_enabled?(conf) do
    ecto_adapter?(conf) and repo_alive?(conf)
  rescue
    _ -> false
  end

  defp repo_alive?(conf) do
    case Keyword.get(conf.persistence, :repo) do
      nil -> false
      repo -> is_pid(GenServer.whereis(repo))
    end
  rescue
    _ -> false
  end

  defp load_from_db(state) do
    case current_conf(state) do
      {:ok, conf} -> load_from_db(state, conf)
      :error -> state
    end
  end

  defp load_from_db(state, conf) do
    cond do
      not ecto_adapter?(conf) ->
        %{state | loaded?: true}

      db_enabled?(conf) ->
        case Bandera.Usage.Ecto.load_into_ets(conf, state.table, return_errors: true) do
          :ok -> %{state | loaded?: true}
          {:error, _reason} -> state
        end

      true ->
        state
    end
  end

  defp flush_to_db(state) do
    with {:ok, conf} <- current_conf(state),
         true <- db_enabled?(conf) do
      Bandera.Usage.Ecto.flush_all(conf, state.table)
    end
  end
end
