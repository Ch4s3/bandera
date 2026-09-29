defmodule Bandera.Store.Persistent.RedisTest do
  use ExUnit.Case, async: false
  @moduletag :redis

  alias Bandera.Config
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

  defp conf, do: Config.get()

  test "put then get round-trips a boolean gate" do
    {:ok, flag} = RedisStore.put(conf(), :f, Gate.new(:boolean, true))
    assert %Flag{name: :f, gates: [%Gate{type: :boolean, enabled: true}]} = flag
    assert {:ok, ^flag} = RedisStore.get(conf(), :f)
  end

  test "get of an unknown flag returns an empty flag" do
    assert {:ok, %Flag{name: :nope, gates: []}} = RedisStore.get(conf(), :nope)
  end

  test "putting the same gate id updates enabled" do
    {:ok, _} = RedisStore.put(conf(), :f, Gate.new(:boolean, true))
    {:ok, flag} = RedisStore.put(conf(), :f, Gate.new(:boolean, false))
    assert [%Gate{type: :boolean, enabled: false}] = flag.gates
  end

  test "actor and group gates coexist and round-trip" do
    {:ok, _} = RedisStore.put(conf(), :f, Gate.new(:actor, %{id: 1}, true))
    {:ok, _} = RedisStore.put(conf(), :f, Gate.new(:group, :admin, false))
    {:ok, %Flag{gates: gates}} = RedisStore.get(conf(), :f)
    assert Enum.any?(gates, &match?(%Gate{type: :actor, for: "1", enabled: true}, &1))
    assert Enum.any?(gates, &match?(%Gate{type: :group, for: "admin", enabled: false}, &1))
  end

  test "both percentage types share one slot; switching kind replaces it" do
    {:ok, _} = RedisStore.put(conf(), :f, Gate.new(:percentage_of_time, 0.3))
    {:ok, flag} = RedisStore.put(conf(), :f, Gate.new(:percentage_of_actors, 0.7))
    assert [%Gate{type: :percentage_of_actors, for: 0.7}] = flag.gates
  end

  test "delete/2 removes one gate; delete/1 removes the whole flag" do
    {:ok, _} = RedisStore.put(conf(), :f, Gate.new(:boolean, true))
    {:ok, _} = RedisStore.put(conf(), :f, Gate.new(:actor, %{id: 1}, true))

    {:ok, flag} = RedisStore.delete(conf(), :f, Gate.new(:actor, %{id: 1}, true))
    assert [%Gate{type: :boolean}] = flag.gates

    {:ok, empty} = RedisStore.delete(conf(), :f)
    assert empty.gates == []
  end

  test "all_flags and all_flag_names" do
    {:ok, _} = RedisStore.put(conf(), :a, Gate.new(:boolean, true))
    {:ok, _} = RedisStore.put(conf(), :b, Gate.new(:boolean, false))

    {:ok, names} = RedisStore.all_flag_names(conf())
    assert Enum.sort(names) == [:a, :b]
    {:ok, flags} = RedisStore.all_flags(conf())
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

  test "child_spec/1 given a keyword list returns a supervisable spec named __MODULE__" do
    assert %{
             id: Bandera.Store.Persistent.Redis,
             start: {Bandera.Store.Persistent.Redis, :start_link, [_]}
           } = RedisStore.child_spec([])
  end

  test "child_spec/1 given a config returns a spec named after the instance" do
    named = Config.new(name: :redis_child_spec_test)

    assert %{
             id: {Bandera.Store.Persistent.Redis, :redis_child_spec_test},
             start: {Bandera.Store.Persistent.Redis, :start_link, [^named]}
           } = RedisStore.child_spec(named)
  end

  test "default-instance keys are unchanged (bandera:flag:<name>, bandera:flag_names)" do
    {:ok, _} = RedisStore.put(conf(), :legacy_key, Gate.new(:boolean, true))

    assert {:ok, ["legacy_key"]} = Redix.command(@conn, ["SMEMBERS", "bandera:flag_names"])
    assert {:ok, [_, _]} = Redix.command(@conn, ["HGETALL", "bandera:flag:legacy_key"])
  end

  describe "named instances" do
    # Clean up through @conn (the default instance's connection, alive for the
    # whole suite) rather than a named instance's own connection — that one
    # stops, along with the rest of the instance, before on_exit runs.
    setup do
      cleanup = fn ->
        for name <- [:redis_inst_a, :redis_inst_b] do
          {:ok, names} = Redix.command(@conn, ["SMEMBERS", "bandera:{#{name}}:flag_names"])
          for n <- names, do: Redix.command(@conn, ["DEL", "bandera:{#{name}}:flag:" <> n])
          Redix.command(@conn, ["DEL", "bandera:{#{name}}:flag_names"])
        end
      end

      cleanup.()
      on_exit(cleanup)

      :ok
    end

    test "two named instances on the same Redis are isolated" do
      start_supervised!({Bandera, name: :redis_inst_a, persistence: [adapter: RedisStore]})
      start_supervised!({Bandera, name: :redis_inst_b, persistence: [adapter: RedisStore]})

      {:ok, true} = Bandera.enable(:shared_name, instance: :redis_inst_a)

      assert Bandera.enabled?(:shared_name, instance: :redis_inst_a)
      refute Bandera.enabled?(:shared_name, instance: :redis_inst_b)
    end

    test "named-instance keys are namespaced" do
      start_supervised!({Bandera, name: :redis_inst_a, persistence: [adapter: RedisStore]})

      {:ok, true} = Bandera.enable(:namespaced, instance: :redis_inst_a)

      conn = Config.get(:redis_inst_a).redis_conn

      assert {:ok, ["namespaced"]} =
               Redix.command(conn, ["SMEMBERS", "bandera:{redis_inst_a}:flag_names"])

      assert {:ok, [_, _]} =
               Redix.command(conn, ["HGETALL", "bandera:{redis_inst_a}:flag:namespaced"])
    end

    test "a named instance's Redis connection is its own, and works end to end" do
      start_supervised!(
        {Bandera,
         name: :redis_inst_a,
         persistence: [adapter: RedisStore],
         store: Bandera.Store.TwoLevel,
         cache: [enabled: true, ttl: 900]}
      )

      conf = Config.get(:redis_inst_a)
      assert conf.redis_conn == :"Elixir.redis_inst_a.Bandera.Store.Persistent.Redis"
      refute conf.redis_conn == @conn

      refute Bandera.enabled?(:end_to_end, instance: :redis_inst_a)
      assert {:ok, true} = Bandera.enable(:end_to_end, instance: :redis_inst_a)
      assert Bandera.enabled?(:end_to_end, instance: :redis_inst_a)
    end
  end
end
