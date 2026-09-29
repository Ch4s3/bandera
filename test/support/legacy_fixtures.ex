# Duck-typed stand-ins for pre-instance extension modules: no @behaviour, so no
# @impl, and credo would otherwise demand specs on every callback.
# credo:disable-for-this-file Credo.Check.Readability.Specs

defmodule Bandera.LegacyStore do
  @moduledoc """
  A store written against the pre-instance, config-less callbacks (`lookup/1`,
  `put/2`, ...). Every flag reads as enabled and writes are reported to the pid in
  `config :bandera, :legacy_test_pid`. Deliberately declares no `@behaviour`: the
  old arities no longer match `Bandera.Store`, and the module must keep working
  through Bandera's legacy dispatch anyway.
  """

  alias Bandera.Flag
  alias Bandera.Gate

  def lookup(flag_name), do: {:ok, Flag.new(flag_name, [Gate.new(:boolean, true)])}
  def put(flag_name, gate), do: report({:legacy_store, :put, flag_name, gate})
  def delete(flag_name, gate), do: report({:legacy_store, :delete, flag_name, gate})
  def delete(flag_name), do: report({:legacy_store, :delete, flag_name})
  def all_flags, do: {:ok, [Flag.new(:legacy_flag, [])]}
  def all_flag_names, do: {:ok, [:legacy_flag]}

  defp report(message) do
    send(Application.fetch_env!(:bandera, :legacy_test_pid), message)
    {:ok, Flag.new(elem(message, 2), [])}
  end
end

defmodule Bandera.LegacyPersistence do
  @moduledoc """
  A persistence adapter written against the pre-instance, config-less callbacks
  (`get/1`, `put/2`, ...), backed by an Agent the test starts. No `@behaviour`
  (see `Bandera.LegacyStore`).
  """
  use Agent

  alias Bandera.Flag
  alias Bandera.Gate

  def start_link(_opts \\ []), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def get(flag_name), do: {:ok, Flag.new(flag_name, gates(flag_name))}

  def put(flag_name, gate) do
    Agent.update(
      __MODULE__,
      &Map.update(&1, flag_name, %{Gate.id(gate) => gate}, fn gates ->
        Map.put(gates, Gate.id(gate), gate)
      end)
    )

    get(flag_name)
  end

  def delete(flag_name, gate) do
    Agent.update(
      __MODULE__,
      &Map.update(&1, flag_name, %{}, fn gates -> Map.delete(gates, Gate.id(gate)) end)
    )

    get(flag_name)
  end

  def delete(flag_name) do
    Agent.update(__MODULE__, &Map.delete(&1, flag_name))
    {:ok, Flag.new(flag_name, [])}
  end

  def all_flags do
    {:ok,
     Agent.get(
       __MODULE__,
       &Enum.map(&1, fn {name, gates} -> Flag.new(name, Map.values(gates)) end)
     )}
  end

  def all_flag_names, do: {:ok, Agent.get(__MODULE__, &Map.keys/1)}

  defp gates(flag_name),
    do: Agent.get(__MODULE__, &(&1 |> Map.get(flag_name, %{}) |> Map.values()))
end

defmodule Bandera.LegacyNotifier do
  @moduledoc """
  A notifier written against the pre-instance callbacks (`publish_change/1`,
  `unique_id/0`); reports to `config :bandera, :legacy_test_pid`. No `@behaviour`
  (see `Bandera.LegacyStore`).
  """

  def publish_change(flag_name) do
    send(Application.fetch_env!(:bandera, :legacy_test_pid), {:legacy_published, flag_name})
    :ok
  end

  def unique_id, do: "legacy-notifier"
end

defmodule Bandera.ClaimingAdapter do
  @moduledoc """
  A persistence adapter that stores nothing but claims the external storage named
  by `persistence: [storage_key: key]`, for exercising instance storage conflicts.
  """
  @behaviour Bandera.Store.Persistent

  alias Bandera.Flag

  @impl true
  def get(_conf, flag_name), do: {:ok, Flag.new(flag_name, [])}
  @impl true
  def put(_conf, flag_name, _gate), do: {:ok, Flag.new(flag_name, [])}
  @impl true
  def delete(_conf, flag_name, _gate), do: {:ok, Flag.new(flag_name, [])}
  @impl true
  def delete(_conf, flag_name), do: {:ok, Flag.new(flag_name, [])}
  @impl true
  def all_flags(_conf), do: {:ok, []}
  @impl true
  def all_flag_names(_conf), do: {:ok, []}
  @impl true
  def storage_id(conf), do: Keyword.get(conf.persistence, :storage_key)
end
