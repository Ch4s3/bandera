defmodule Bandera.Store.Cache do
  @moduledoc """
  ETS read cache for flags, one table per instance. Always started under the
  instance; bypassed by the store when the instance's cache is disabled (so the
  cache can be toggled at runtime without races). The TTL is read from the
  instance's `Bandera.Config` at lookup time.

  Note: a TTL of `0` causes every entry to expire immediately on the next read
  (it is not "no expiry"). To disable caching entirely, set `cache: [enabled: false]`.

  The single-argument functions (`get/1`, `put/1`, `bust/1`, `flush/0`) act on the
  default instance's cache and exist for backward compatibility.
  """

  use GenServer

  alias Bandera.Config
  alias Bandera.Flag

  @doc """
  Starts the cache GenServer (which owns the backing ETS table).

  Given a `%Bandera.Config{}`, the table and process are named `conf.cache_table`;
  given a keyword list (e.g. `start_supervised!(Bandera.Store.Cache)`), the
  default instance's cache is started.
  """
  @spec start_link(Config.t() | keyword) :: GenServer.on_start()
  def start_link(conf_or_opts \\ [])

  def start_link(%Config{cache_table: table}),
    do: GenServer.start_link(__MODULE__, table, name: table)

  def start_link(opts) when is_list(opts), do: start_link(Config.new())

  @impl GenServer
  def init(table) do
    :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Reads a flag from `conf`'s cache.

  Returns `{:ok, flag}` on a live hit, or `{:miss, :not_found}` / `{:miss, :expired}`
  so the caller can fall through to the persistent store. Expiry is evaluated against
  `conf.cache_ttl` at read time.

  ## Examples

      iex> conf = Bandera.Config.get()
      iex> Bandera.Store.Cache.get(conf, :absent)
      {:miss, :not_found}

      iex> conf = Bandera.Config.get()
      iex> Bandera.Store.Cache.put(conf, Bandera.Flag.new(:demo, []))
      iex> Bandera.Store.Cache.get(conf, :demo)
      {:ok, %Bandera.Flag{name: :demo, gates: []}}
  """
  @spec get(Config.t(), atom) :: {:ok, Flag.t()} | {:miss, :not_found | :expired}
  def get(%Config{cache_table: table, cache_ttl: ttl}, flag_name) do
    case :ets.lookup(table, flag_name) do
      [] ->
        {:miss, :not_found}

      [{^flag_name, flag, inserted_at}] ->
        if now() - inserted_at >= ttl, do: {:miss, :expired}, else: {:ok, flag}
    end
  end

  @doc """
  Caches `flag` in `conf`'s cache with a fresh timestamp and returns it unchanged
  (for pipelining).

  ## Examples

      iex> Bandera.Store.Cache.put(Bandera.Config.get(), Bandera.Flag.new(:demo, []))
      %Bandera.Flag{name: :demo, gates: []}
  """
  @spec put(Config.t(), Flag.t()) :: Flag.t()
  def put(%Config{cache_table: table}, %Flag{name: name} = flag) do
    :ets.insert(table, {name, flag, now()})
    flag
  end

  @doc """
  Evicts a single flag's entry from `conf`'s cache. Used by cache-busting notifications.

  ## Examples

      iex> conf = Bandera.Config.get()
      iex> Bandera.Store.Cache.put(conf, Bandera.Flag.new(:demo, []))
      iex> Bandera.Store.Cache.bust(conf, :demo)
      :ok
      iex> Bandera.Store.Cache.get(conf, :demo)
      {:miss, :not_found}
  """
  @spec bust(Config.t(), atom) :: :ok
  def bust(%Config{cache_table: table}, flag_name) do
    :ets.delete(table, flag_name)
    :ok
  end

  @doc """
  Evicts every entry from `conf`'s cache.

  ## Examples

      iex> conf = Bandera.Config.get()
      iex> Bandera.Store.Cache.put(conf, Bandera.Flag.new(:demo, []))
      iex> Bandera.Store.Cache.flush(conf)
      :ok
      iex> Bandera.Store.Cache.get(conf, :demo)
      {:miss, :not_found}
  """
  @spec flush(Config.t()) :: :ok
  def flush(%Config{cache_table: table}) do
    :ets.delete_all_objects(table)
    :ok
  end

  # ---- default-instance shorthands (backward compatibility) ----

  @doc "Reads a flag from the default instance's cache. See `get/2`."
  @spec get(atom) :: {:ok, Flag.t()} | {:miss, :not_found | :expired}
  def get(flag_name) when is_atom(flag_name), do: get(Config.get(), flag_name)

  @doc "Caches `flag` in the default instance's cache. See `put/2`."
  @spec put(Flag.t()) :: Flag.t()
  def put(%Flag{} = flag), do: put(Config.get(), flag)

  @doc "Evicts a flag from the default instance's cache. See `bust/2`."
  @spec bust(atom) :: :ok
  def bust(flag_name) when is_atom(flag_name), do: bust(Config.get(), flag_name)

  @doc "Evicts every entry from the default instance's cache. See `flush/1`."
  @spec flush() :: :ok
  def flush, do: flush(Config.get())

  defp now, do: System.monotonic_time(:second)
end
