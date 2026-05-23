defmodule Bandera.RulesTest do
  use ExUnit.Case, async: false
  alias Bandera.Store.Cache
  alias Bandera.Store.Persistent.Memory

  setup do
    start_supervised!(Memory)
    start_supervised!(Cache)
    Application.put_env(:bandera, :cache, enabled: true, ttl: 900)
    Application.put_env(:bandera, :persistence, adapter: Memory)
    Application.put_env(:bandera, :store, Bandera.Store.TwoLevel)
    Bandera.reload_config()

    on_exit(fn ->
      Application.delete_env(:bandera, :cache)
      Application.delete_env(:bandera, :persistence)
      Application.delete_env(:bandera, :store)
      Bandera.reload_config()
    end)

    :ok
  end

  test "enable(when:) gates on context attributes" do
    assert {:ok, true} =
             Bandera.enable(:billing, when: [{"plan", :eq, "premium"}, {"country", :eq, "US"}])

    assert Bandera.enabled?(:billing, context: %{"plan" => "premium", "country" => "US"})
    refute Bandera.enabled?(:billing, context: %{"plan" => "free", "country" => "US"})
  end

  test "clear(rule: true) removes the rule gate" do
    {:ok, _} = Bandera.enable(:promo, when: [{"plan", :eq, "pro"}])
    {:ok, flag} = Bandera.get_flag(:promo)
    assert Enum.any?(flag.gates, &Bandera.Gate.rule?/1)

    assert :ok = Bandera.clear(:promo, rule: true)
    {:ok, flag} = Bandera.get_flag(:promo)
    refute Enum.any?(flag.gates, &Bandera.Gate.rule?/1)
  end
end
