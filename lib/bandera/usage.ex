defmodule Bandera.Usage do
  @moduledoc """
  Optional last-evaluated tracker. Attaches to `[:bandera, :enabled?]` and
  `[:bandera, :variant]` and records, in ETS, the last time each flag was evaluated
  — the signal for `Bandera.stale_flags/1`. Tracking both events means a flag used
  only through `Bandera.variant/2` is not mistaken for stale.

  Start it in your supervision tree and call `Bandera.Usage.attach/0` once at boot.
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

  @doc "Subscribe the tracker to the flag-evaluation telemetry events."
  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    :telemetry.attach_many(@handler, @events, &__MODULE__.handle/4, nil)
  end

  @doc "Unsubscribe the tracker from telemetry."
  @spec detach() :: :ok | {:error, :not_found}
  def detach, do: :telemetry.detach(@handler)

  @doc false
  def handle(_event, _measurements, %{flag_name: flag_name}, _config) do
    :ets.insert(@table, {flag_name, DateTime.utc_now()})
    :ok
  end

  @doc """
  Returns the last time `flag_name` was evaluated, or `nil` if never (or if the
  tracker isn't running — it is opt-in).
  """
  @spec last_evaluated(atom) :: DateTime.t() | nil
  def last_evaluated(flag_name) do
    case :ets.whereis(@table) do
      :undefined ->
        nil

      _ref ->
        case :ets.lookup(@table, flag_name) do
          [{^flag_name, at}] -> at
          [] -> nil
        end
    end
  end
end
