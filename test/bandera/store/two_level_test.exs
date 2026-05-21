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
    {:ok, flag} = TwoLevel.put(:f, Gate.new(:boolean, true))
    assert {:ok, ^flag} = Memory.get(:f)
    assert {:ok, ^flag} = Cache.get(:f)
  end

  test "lookup serves from cache after first read" do
    {:ok, _} = Memory.put(:f, Gate.new(:boolean, true))
    Cache.flush()
    assert {:ok, flag} = TwoLevel.lookup(:f)
    assert {:ok, ^flag} = Cache.get(:f)
  end

  test "cache can be toggled OFF at runtime with no recompilation" do
    {:ok, _} = TwoLevel.put(:f, Gate.new(:boolean, true))
    # Stale cache entry written directly:
    Cache.put(Bandera.Flag.new(:f, [Gate.new(:boolean, false)]))

    # With cache ON, the stale value is served:
    assert {:ok, %{gates: [%Gate{enabled: false}]}} = TwoLevel.lookup(:f)

    # Toggle cache OFF at runtime:
    Application.put_env(:bandera, :cache, enabled: false, ttl: 900)
    Config.reload()

    # Now reads bypass the cache and hit persistent (true):
    assert {:ok, %{gates: [%Gate{enabled: true}]}} = TwoLevel.lookup(:f)
  end

  test "delete/2 writes through to persistent and updates the cache" do
    {:ok, _} = TwoLevel.put(:f, Gate.new(:boolean, true))
    {:ok, _} = TwoLevel.put(:f, Gate.new(:actor, %{id: 1}, true))

    {:ok, flag} = TwoLevel.delete(:f, Gate.new(:actor, %{id: 1}, true))
    assert [%Gate{type: :boolean}] = flag.gates
    assert {:ok, ^flag} = Memory.get(:f)
    assert {:ok, ^flag} = Cache.get(:f)
  end

  test "delete/1 writes through to persistent and updates the cache" do
    {:ok, _} = TwoLevel.put(:f, Gate.new(:boolean, true))

    {:ok, flag} = TwoLevel.delete(:f)
    assert flag.gates == []
    assert {:ok, ^flag} = Memory.get(:f)
    assert {:ok, ^flag} = Cache.get(:f)
  end

  test "writing while the cache is disabled invalidates a stale cache entry" do
    {:ok, _} = TwoLevel.put(:f, Gate.new(:boolean, true))
    assert {:ok, %{gates: [%Gate{enabled: true}]}} = Cache.get(:f)

    # Disable cache, then write a new value: the stale entry must be busted.
    Application.put_env(:bandera, :cache, enabled: false, ttl: 900)
    Config.reload()
    {:ok, _} = TwoLevel.put(:f, Gate.new(:boolean, false))
    assert {:miss, _} = Cache.get(:f)

    # Re-enable: lookup must reflect the persistent (false) value, not the stale true.
    Application.put_env(:bandera, :cache, enabled: true, ttl: 900)
    Config.reload()
    assert {:ok, %{gates: [%Gate{enabled: false}]}} = TwoLevel.lookup(:f)
  end
end
