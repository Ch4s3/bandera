defmodule Bandera.Store.Persistent.Memory do
  @moduledoc """
  In-memory (ETS) persistence adapter. The default backend; suitable for
  single-node deployments and development. Not durable across restarts.

  Each instance gets its own table (`conf.memory_table`), so instances never see
  each other's flags. Rows are keyed by `{flag_name, gate_id}` so each gate has
  exactly one slot (both percentage gate types share the `"percentage"` slot).

  ## Examples

      iex> alias Bandera.Store.Persistent.Memory
      iex> conf = Bandera.Config.get()
      iex> Memory.put(conf, :demo, Bandera.Gate.new(:boolean, true))
      iex> {:ok, flag} = Memory.get(conf, :demo)
      iex> flag.gates
      [%Bandera.Gate{type: :boolean, for: nil, enabled: true}]
      iex> Memory.all_flag_names(conf)
      {:ok, [:demo]}
  """

  use GenServer
  @behaviour Bandera.Store.Persistent

  alias Bandera.Config
  alias Bandera.Flag
  alias Bandera.Gate

  @doc """
  Starts the adapter GenServer, which owns the backing ETS table.

  Given a `%Bandera.Config{}`, the table and process are named `conf.memory_table`;
  given a keyword list (e.g. `start_supervised!(Bandera.Store.Persistent.Memory)`),
  the default instance's table is started.
  """
  @spec start_link(Config.t() | keyword) :: GenServer.on_start()
  def start_link(conf_or_opts \\ [])

  def start_link(%Config{memory_table: table}),
    do: GenServer.start_link(__MODULE__, table, name: table)

  def start_link(opts) when is_list(opts), do: start_link(Config.new())

  @impl GenServer
  def init(table) do
    :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl Bandera.Store.Persistent
  def get(%Config{memory_table: table}, flag_name) do
    gates =
      table
      |> :ets.match_object({{flag_name, :_}, :_})
      |> Enum.map(fn {_key, gate} -> gate end)

    {:ok, Flag.new(flag_name, gates)}
  end

  @impl Bandera.Store.Persistent
  def put(%Config{memory_table: table} = conf, flag_name, %Gate{} = gate) do
    :ets.insert(table, {{flag_name, Gate.id(gate)}, gate})
    get(conf, flag_name)
  end

  @impl Bandera.Store.Persistent
  def delete(%Config{memory_table: table} = conf, flag_name, %Gate{} = gate) do
    :ets.delete(table, {flag_name, Gate.id(gate)})
    get(conf, flag_name)
  end

  @impl Bandera.Store.Persistent
  def delete(%Config{memory_table: table}, flag_name) do
    :ets.match_delete(table, {{flag_name, :_}, :_})
    {:ok, Flag.new(flag_name, [])}
  end

  def delete(flag_name, %Gate{} = gate) when is_atom(flag_name),
    do: delete(Config.get(), flag_name, gate)

  @impl Bandera.Store.Persistent
  def all_flag_names(%Config{memory_table: table}) do
    names =
      table
      |> :ets.match({{:"$1", :_}, :_})
      |> Enum.map(&hd/1)
      |> Enum.uniq()

    {:ok, names}
  end

  @impl Bandera.Store.Persistent
  def all_flags(%Config{memory_table: table}) do
    flags =
      table
      |> :ets.tab2list()
      |> Enum.group_by(
        fn {{flag_name, _gate_id}, _gate} -> flag_name end,
        fn {_key, gate} -> gate end
      )
      |> Enum.map(fn {flag_name, gates} -> Flag.new(flag_name, gates) end)

    {:ok, flags}
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
