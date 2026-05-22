defmodule Bandera.Usage do
  @moduledoc """
  Optional last-evaluated tracker. Attaches to `[:bandera, :enabled?]` and
  `[:bandera, :variant]` and records, in ETS, the last time each flag was checked —
  the signal for `Bandera.stale_flags/1`. Start it in your supervision tree and call
  `Bandera.Usage.attach/0` once at boot.
  """
  use GenServer

  @table __MODULE__
  @handler {__MODULE__, :usage}
  @events [[:bandera, :enabled?], [:bandera, :variant]]

  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, %{}}
  end

  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    :telemetry.attach_many(@handler, @events, &__MODULE__.handle/4, nil)
  end

  @spec detach() :: :ok | {:error, :not_found}
  def detach, do: :telemetry.detach(@handler)

  @doc false
  @spec handle(list, map, map, term) :: :ok
  def handle([:bandera, _event], _measurements, %{flag_name: flag_name}, _config) do
    :ets.insert(@table, {flag_name, DateTime.utc_now()})
    :ok
  end

  @spec last_evaluated(atom) :: DateTime.t() | nil
  def last_evaluated(flag_name) do
    case :ets.lookup(@table, flag_name) do
      [{^flag_name, at}] -> at
      [] -> nil
    end
  end
end
