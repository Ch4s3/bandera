defmodule Bandera.Store.Cache do
  @moduledoc """
  ETS read cache for flags. Always started; bypassed by the store when the cache
  is disabled (so the cache can be toggled at runtime without races). The TTL is
  read from the runtime `Bandera.Config` snapshot at lookup time.

  Note: a TTL of `0` causes every entry to expire immediately on the next read
  (it is not "no expiry"). To disable caching entirely, set `cache: [enabled: false]`.
  """

  use GenServer

  alias Bandera.Config
  alias Bandera.Flag

  @table __MODULE__

  @doc "Starts the cache GenServer (which owns the backing ETS table) under its module name."
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Reads a flag from the cache.

  Returns `{:ok, flag}` on a live hit, or `{:miss, :not_found}` / `{:miss, :expired}`
  so the caller can fall through to the persistent store. Expiry is evaluated against
  the current `Bandera.Config.cache_ttl/0` at read time.

  ## Examples

      iex> Bandera.Store.Cache.get(:absent)
      {:miss, :not_found}

      iex> Bandera.Store.Cache.put(Bandera.Flag.new(:demo, []))
      iex> Bandera.Store.Cache.get(:demo)
      {:ok, %Bandera.Flag{name: :demo, gates: []}}
  """
  @spec get(atom) :: {:ok, Flag.t()} | {:miss, :not_found | :expired}
  def get(flag_name) do
    case :ets.lookup(@table, flag_name) do
      [] ->
        {:miss, :not_found}

      [{^flag_name, flag, inserted_at}] ->
        if expired?(inserted_at), do: {:miss, :expired}, else: {:ok, flag}
    end
  end

  @doc """
  Caches `flag` with a fresh timestamp and returns it unchanged (for pipelining).

  ## Examples

      iex> Bandera.Store.Cache.put(Bandera.Flag.new(:demo, []))
      %Bandera.Flag{name: :demo, gates: []}
  """
  @spec put(Flag.t()) :: Flag.t()
  def put(%Flag{name: name} = flag) do
    :ets.insert(@table, {name, flag, now()})
    flag
  end

  @doc """
  Evicts a single flag's cache entry. Used by cache-busting notifications.

  ## Examples

      iex> Bandera.Store.Cache.put(Bandera.Flag.new(:demo, []))
      iex> Bandera.Store.Cache.bust(:demo)
      :ok
      iex> Bandera.Store.Cache.get(:demo)
      {:miss, :not_found}
  """
  @spec bust(atom) :: :ok
  def bust(flag_name) do
    :ets.delete(@table, flag_name)
    :ok
  end

  @doc """
  Evicts every cache entry.

  ## Examples

      iex> Bandera.Store.Cache.put(Bandera.Flag.new(:demo, []))
      iex> Bandera.Store.Cache.flush()
      :ok
      iex> Bandera.Store.Cache.get(:demo)
      {:miss, :not_found}
  """
  @spec flush() :: :ok
  def flush do
    :ets.delete_all_objects(@table)
    :ok
  end

  defp now, do: System.monotonic_time(:second)

  defp expired?(inserted_at) do
    now() - inserted_at >= Config.cache_ttl()
  end
end
