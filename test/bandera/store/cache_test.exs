defmodule Bandera.Store.CacheTest do
  use ExUnit.Case, async: false
  alias Bandera.Config
  alias Bandera.Flag
  alias Bandera.Store.Cache

  doctest Bandera.Store.Cache

  setup do
    start_supervised!(Cache)
    Application.put_env(:bandera, :cache, enabled: true, ttl: 900)
    Config.reload()

    on_exit(fn ->
      Application.delete_env(:bandera, :cache)
      Config.reload()
    end)

    :ok
  end

  test "miss then hit" do
    assert {:miss, :not_found} = Cache.get(:f)
    flag = Flag.new(:f, [])
    assert ^flag = Cache.put(flag)
    assert {:ok, ^flag} = Cache.get(:f)
  end

  test "entries expire based on the runtime TTL" do
    Application.put_env(:bandera, :cache, enabled: true, ttl: 0)
    Config.reload()
    Cache.put(Flag.new(:f, []))
    assert {:miss, :expired} = Cache.get(:f)
  end

  test "bust/1 removes a single entry; flush/0 clears all" do
    Cache.put(Flag.new(:a, []))
    Cache.put(Flag.new(:b, []))
    Cache.bust(:a)
    assert {:miss, _} = Cache.get(:a)
    assert {:ok, _} = Cache.get(:b)
    Cache.flush()
    assert {:miss, _} = Cache.get(:b)
  end
end
