defmodule Bandera.Store.Persistent.EctoTest do
  use ExUnit.Case, async: false

  alias Bandera.Flag
  alias Bandera.Gate
  alias Bandera.Store.Persistent.Ecto, as: EctoStore

  setup do
    Bandera.TestRepo.query!("DELETE FROM bandera_flags")
    Application.put_env(:bandera, :persistence, adapter: EctoStore, repo: Bandera.TestRepo)
    Bandera.reload_config()

    on_exit(fn ->
      Application.delete_env(:bandera, :persistence)
      Bandera.reload_config()
    end)

    :ok
  end

  test "put then get round-trips a boolean gate" do
    {:ok, flag} = EctoStore.put(:f, Gate.new(:boolean, true))
    assert %Flag{name: :f, gates: [%Gate{type: :boolean, enabled: true}]} = flag
    assert {:ok, ^flag} = EctoStore.get(:f)
  end

  test "get of an unknown flag returns an empty flag" do
    assert {:ok, %Flag{name: :nope, gates: []}} = EctoStore.get(:nope)
  end

  test "putting the same gate id updates enabled (upsert)" do
    {:ok, _} = EctoStore.put(:f, Gate.new(:boolean, true))
    {:ok, flag} = EctoStore.put(:f, Gate.new(:boolean, false))
    assert [%Gate{type: :boolean, enabled: false}] = flag.gates
  end

  test "actor and group gates coexist and round-trip" do
    {:ok, _} = EctoStore.put(:f, Gate.new(:actor, %{id: 1}, true))
    {:ok, _} = EctoStore.put(:f, Gate.new(:group, :admin, false))
    {:ok, %Flag{gates: gates}} = EctoStore.get(:f)
    assert Enum.any?(gates, &match?(%Gate{type: :actor, for: "1", enabled: true}, &1))
    assert Enum.any?(gates, &match?(%Gate{type: :group, for: "admin", enabled: false}, &1))
  end

  test "both percentage types share one slot; switching kind replaces it" do
    {:ok, _} = EctoStore.put(:f, Gate.new(:percentage_of_time, 0.3))
    {:ok, flag} = EctoStore.put(:f, Gate.new(:percentage_of_actors, 0.7))
    assert [%Gate{type: :percentage_of_actors, for: 0.7}] = flag.gates
  end

  test "delete/2 removes one gate; delete/1 removes the whole flag" do
    {:ok, _} = EctoStore.put(:f, Gate.new(:boolean, true))
    {:ok, _} = EctoStore.put(:f, Gate.new(:actor, %{id: 1}, true))

    {:ok, flag} = EctoStore.delete(:f, Gate.new(:actor, %{id: 1}, true))
    assert [%Gate{type: :boolean}] = flag.gates

    {:ok, empty} = EctoStore.delete(:f)
    assert empty.gates == []
  end

  test "delete/2 with a percentage gate clears the percentage slot" do
    {:ok, _} = EctoStore.put(:f, Gate.new(:percentage_of_actors, 0.5))
    # deleting with EITHER percentage type clears the single percentage slot
    {:ok, flag} = EctoStore.delete(:f, Gate.new(:percentage_of_time, 0.5))
    assert flag.gates == []
  end

  test "all_flags and all_flag_names" do
    {:ok, _} = EctoStore.put(:a, Gate.new(:boolean, true))
    {:ok, _} = EctoStore.put(:b, Gate.new(:boolean, false))

    {:ok, names} = EctoStore.all_flag_names()
    assert Enum.sort(names) == [:a, :b]
    {:ok, flags} = EctoStore.all_flags()
    assert length(flags) == 2
  end

  test "variant gate persists and resolves through the Ecto adapter" do
    alias Bandera.Store.Persistent.Ecto, as: EctoStore

    {:ok, _flag} = EctoStore.put(:hero, Bandera.Gate.new(:variant, %{"a" => 1, "b" => 1}))
    {:ok, flag} = EctoStore.get(:hero)

    assert [%Bandera.Gate{type: :variant, value: %{"a" => 1, "b" => 1}}] = flag.gates
    v = Bandera.Flag.variant(flag, for: %{id: 7})
    assert v in ["a", "b"]
  end

  test "rule gate round-trips through the value column and evaluates with context" do
    gate = Gate.new(:rule, [Bandera.Constraint.new("plan", :eq, "premium")], true)
    {:ok, _} = EctoStore.put(:billing, gate)
    {:ok, flag} = EctoStore.get(:billing)

    assert [%Gate{type: :rule}] = flag.gates
    assert Flag.enabled?(flag, context: %{"plan" => "premium"})
    refute Flag.enabled?(flag, context: %{"plan" => "free"})
  end

  test "schedule gate round-trips through the value column and gates by window" do
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
    future = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_iso8601()

    {:ok, _} = EctoStore.put(:launch, Gate.new(:schedule, {past, future}))
    {:ok, flag} = EctoStore.get(:launch)

    assert [%Gate{type: :schedule, value: %{"from" => ^past, "until" => ^future}}] = flag.gates
    assert Flag.enabled?(flag)
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
end
