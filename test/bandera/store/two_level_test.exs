defmodule Bandera.Store.TwoLevelTest do
  use ExUnit.Case, async: false
  alias Bandera.Config
  alias Bandera.Gate
  alias Bandera.Store.Cache
  alias Bandera.Store.Persistent.Memory
  alias Bandera.Store.TwoLevel

  doctest Bandera.Store.TwoLevel

  setup do
    start_supervised!(Memory)
    start_supervised!(Cache)
    Application.put_env(:bandera, :cache, enabled: true, ttl: 900)
    Application.put_env(:bandera, :persistence, adapter: Memory)
    Config.reload()

    on_exit(fn ->
      Application.delete_env(:bandera, :cache)
      Application.delete_env(:bandera, :persistence)
      Config.reload()
    end)

    :ok
  end

  test "put writes through to persistent and caches the result" do
    {:ok, flag} = TwoLevel.put(conf(), :f, Gate.new(:boolean, true))
    assert {:ok, ^flag} = Memory.get(conf(), :f)
    assert {:ok, ^flag} = Cache.get(:f)
  end

  test "lookup serves from cache after first read" do
    {:ok, _} = Memory.put(conf(), :f, Gate.new(:boolean, true))
    Cache.flush()
    assert {:ok, flag} = TwoLevel.lookup(conf(), :f)
    assert {:ok, ^flag} = Cache.get(:f)
  end

  test "cache can be toggled OFF at runtime with no recompilation" do
    {:ok, _} = TwoLevel.put(conf(), :f, Gate.new(:boolean, true))
    # Stale cache entry written directly:
    Cache.put(Bandera.Flag.new(:f, [Gate.new(:boolean, false)]))

    # With cache ON, the stale value is served:
    assert {:ok, %{gates: [%Gate{enabled: false}]}} = TwoLevel.lookup(conf(), :f)

    # Toggle cache OFF at runtime:
    Application.put_env(:bandera, :cache, enabled: false, ttl: 900)
    Config.reload()

    # Now reads bypass the cache and hit persistent (true):
    assert {:ok, %{gates: [%Gate{enabled: true}]}} = TwoLevel.lookup(conf(), :f)
  end

  test "delete/2 writes through to persistent and updates the cache" do
    {:ok, _} = TwoLevel.put(conf(), :f, Gate.new(:boolean, true))
    {:ok, _} = TwoLevel.put(conf(), :f, Gate.new(:actor, %{id: 1}, true))

    {:ok, flag} = TwoLevel.delete(conf(), :f, Gate.new(:actor, %{id: 1}, true))
    assert [%Gate{type: :boolean}] = flag.gates
    assert {:ok, ^flag} = Memory.get(conf(), :f)
    assert {:ok, ^flag} = Cache.get(:f)
  end

  test "delete/1 writes through to persistent and updates the cache" do
    {:ok, _} = TwoLevel.put(conf(), :f, Gate.new(:boolean, true))

    {:ok, flag} = TwoLevel.delete(conf(), :f)
    assert flag.gates == []
    assert {:ok, ^flag} = Memory.get(conf(), :f)
    assert {:ok, ^flag} = Cache.get(:f)
  end

  test "writing while the cache is disabled invalidates a stale cache entry" do
    {:ok, _} = TwoLevel.put(conf(), :f, Gate.new(:boolean, true))
    assert {:ok, %{gates: [%Gate{enabled: true}]}} = Cache.get(:f)

    # Disable cache, then write a new value: the stale entry must be busted.
    Application.put_env(:bandera, :cache, enabled: false, ttl: 900)
    Config.reload()
    {:ok, _} = TwoLevel.put(conf(), :f, Gate.new(:boolean, false))
    assert {:miss, _} = Cache.get(:f)

    # Re-enable: lookup must reflect the persistent (false) value, not the stale true.
    Application.put_env(:bandera, :cache, enabled: true, ttl: 900)
    Config.reload()
    assert {:ok, %{gates: [%Gate{enabled: false}]}} = TwoLevel.lookup(conf(), :f)
  end

  test "the pre-instance arities act on the default instance" do
    {:ok, flag} = TwoLevel.put(:legacy, Gate.new(:boolean, true))
    assert {:ok, ^flag} = TwoLevel.lookup(:legacy)
    assert {:ok, ^flag} = Memory.get(conf(), :legacy)

    {:ok, _} = TwoLevel.put(:legacy, Gate.new(:actor, %{id: 1}, true))

    assert {:ok, %{gates: [%Gate{type: :boolean}]}} =
             TwoLevel.delete(:legacy, Gate.new(:actor, %{id: 1}, true))

    assert {:ok, [:legacy]} = TwoLevel.all_flag_names()
    assert {:ok, [%{name: :legacy}]} = TwoLevel.all_flags()
    assert {:ok, %{gates: []}} = TwoLevel.delete(:legacy)
    assert {:ok, %{gates: []}} = TwoLevel.lookup(conf(), :legacy)
  end

  defp conf, do: Bandera.Config.get()
end
