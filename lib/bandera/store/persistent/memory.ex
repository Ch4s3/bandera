defmodule Bandera.Store.Persistent.Memory do
  @moduledoc """
  In-memory (ETS) persistence adapter. The default backend; suitable for
  single-node deployments and development. Not durable across restarts.

  Rows are keyed by `{flag_name, gate_id}` so each gate has exactly one slot
  (both percentage gate types share the `"percentage"` slot).
  """

  use GenServer
  @behaviour Bandera.Store.Persistent

  alias Bandera.Flag
  alias Bandera.Gate

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

  @impl Bandera.Store.Persistent
  def get(flag_name) do
    gates =
      @table
      |> :ets.match_object({{flag_name, :_}, :_})
      |> Enum.map(fn {_key, gate} -> gate end)

    {:ok, Flag.new(flag_name, gates)}
  end

  @impl Bandera.Store.Persistent
  def put(flag_name, %Gate{} = gate) do
    :ets.insert(@table, {{flag_name, Gate.id(gate)}, gate})
    get(flag_name)
  end

  @impl Bandera.Store.Persistent
  def delete(flag_name, %Gate{} = gate) do
    :ets.delete(@table, {flag_name, Gate.id(gate)})
    get(flag_name)
  end

  @impl Bandera.Store.Persistent
  def delete(flag_name) do
    :ets.match_delete(@table, {{flag_name, :_}, :_})
    {:ok, Flag.new(flag_name, [])}
  end

  @impl Bandera.Store.Persistent
  def all_flag_names do
    names =
      @table
      |> :ets.match({{:"$1", :_}, :_})
      |> Enum.map(&hd/1)
      |> Enum.uniq()

    {:ok, names}
  end

  @impl Bandera.Store.Persistent
  def all_flags do
    flags =
      @table
      |> :ets.tab2list()
      |> Enum.group_by(
        fn {{flag_name, _gate_id}, _gate} -> flag_name end,
        fn {_key, gate} -> gate end
      )
      |> Enum.map(fn {flag_name, gates} -> Flag.new(flag_name, gates) end)

    {:ok, flags}
  end
end
