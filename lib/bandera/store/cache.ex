defmodule Bandera.Store.Cache do
  @moduledoc """
  ETS read cache for flags. Always started; bypassed by the store when the cache
  is disabled (so the cache can be toggled at runtime without races). The TTL is
  read from the runtime `Bandera.Config` snapshot at lookup time.
  """

  use GenServer

  alias Bandera.Config
  alias Bandera.Flag

  @table __MODULE__

  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @spec get(atom) :: {:ok, Flag.t()} | {:miss, :not_found | :expired}
  def get(flag_name) do
    case :ets.lookup(@table, flag_name) do
      [] ->
        {:miss, :not_found}

      [{^flag_name, flag, inserted_at}] ->
        if expired?(inserted_at), do: {:miss, :expired}, else: {:ok, flag}
    end
  end

  @spec put(Flag.t()) :: Flag.t()
  def put(%Flag{name: name} = flag) do
    :ets.insert(@table, {name, flag, now()})
    flag
  end

  @spec bust(atom) :: :ok
  def bust(flag_name) do
    :ets.delete(@table, flag_name)
    :ok
  end

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
