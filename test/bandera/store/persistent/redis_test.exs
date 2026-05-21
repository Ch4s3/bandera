defmodule Bandera.Store.Persistent.RedisTest do
  use ExUnit.Case, async: false
  @moduletag :redis

  alias Bandera.Flag
  alias Bandera.Gate
  alias Bandera.Store.Persistent.Redis, as: RedisStore

  @conn Bandera.Store.Persistent.Redis

  setup do
    {:ok, names} = Redix.command(@conn, ["SMEMBERS", "bandera:flag_names"])
    for n <- names, do: Redix.command(@conn, ["DEL", "bandera:flag:" <> n])
    Redix.command(@conn, ["DEL", "bandera:flag_names"])

    Application.put_env(:bandera, :persistence, adapter: RedisStore)
    Bandera.reload_config()

    on_exit(fn ->
      Application.delete_env(:bandera, :persistence)
      Bandera.reload_config()
    end)

    :ok
  end

  test "put then get round-trips a boolean gate" do
    {:ok, flag} = RedisStore.put(:f, Gate.new(:boolean, true))
    assert %Flag{name: :f, gates: [%Gate{type: :boolean, enabled: true}]} = flag
    assert {:ok, ^flag} = RedisStore.get(:f)
  end

  test "get of an unknown flag returns an empty flag" do
    assert {:ok, %Flag{name: :nope, gates: []}} = RedisStore.get(:nope)
  end

  test "putting the same gate id updates enabled" do
    {:ok, _} = RedisStore.put(:f, Gate.new(:boolean, true))
    {:ok, flag} = RedisStore.put(:f, Gate.new(:boolean, false))
    assert [%Gate{type: :boolean, enabled: false}] = flag.gates
  end

  test "actor and group gates coexist and round-trip" do
    {:ok, _} = RedisStore.put(:f, Gate.new(:actor, %{id: 1}, true))
    {:ok, _} = RedisStore.put(:f, Gate.new(:group, :admin, false))
    {:ok, %Flag{gates: gates}} = RedisStore.get(:f)
    assert Enum.any?(gates, &match?(%Gate{type: :actor, for: "1", enabled: true}, &1))
    assert Enum.any?(gates, &match?(%Gate{type: :group, for: "admin", enabled: false}, &1))
  end

  test "both percentage types share one slot; switching kind replaces it" do
    {:ok, _} = RedisStore.put(:f, Gate.new(:percentage_of_time, 0.3))
    {:ok, flag} = RedisStore.put(:f, Gate.new(:percentage_of_actors, 0.7))
    assert [%Gate{type: :percentage_of_actors, for: 0.7}] = flag.gates
  end

  test "delete/2 removes one gate; delete/1 removes the whole flag" do
    {:ok, _} = RedisStore.put(:f, Gate.new(:boolean, true))
    {:ok, _} = RedisStore.put(:f, Gate.new(:actor, %{id: 1}, true))

    {:ok, flag} = RedisStore.delete(:f, Gate.new(:actor, %{id: 1}, true))
    assert [%Gate{type: :boolean}] = flag.gates

    {:ok, empty} = RedisStore.delete(:f)
    assert empty.gates == []
  end

  test "all_flags and all_flag_names" do
    {:ok, _} = RedisStore.put(:a, Gate.new(:boolean, true))
    {:ok, _} = RedisStore.put(:b, Gate.new(:boolean, false))

    {:ok, names} = RedisStore.all_flag_names()
    assert Enum.sort(names) == [:a, :b]
    {:ok, flags} = RedisStore.all_flags()
    assert length(flags) == 2
  end

  test "works end-to-end through the public Bandera API via TwoLevel" do
    start_supervised!(Bandera.Store.Cache)
    Application.put_env(:bandera, :store, Bandera.Store.TwoLevel)
    Application.put_env(:bandera, :cache, enabled: true, ttl: 900)
    Bandera.reload_config()

    on_exit(fn ->
      Application.delete_env(:bandera, :store)
      Application.delete_env(:bandera, :cache)
      Bandera.reload_config()
    end)

    refute Bandera.enabled?(:api_flag)
    assert {:ok, true} = Bandera.enable(:api_flag)
    assert Bandera.enabled?(:api_flag)
  end

  test "child_spec/1 returns a supervisable spec" do
    assert %{
             id: Bandera.Store.Persistent.Redis,
             start: {Bandera.Store.Persistent.Redis, :start_link, [_]}
           } = RedisStore.child_spec([])
  end
end
