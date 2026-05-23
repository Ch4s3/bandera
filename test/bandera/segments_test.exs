defmodule Bandera.SegmentsTest do
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

  test "put_segment stores a reusable named constraint set" do
    assert {:ok, _} =
             Bandera.put_segment(:premium_us, [
               {"plan", :eq, "premium"},
               {"country", :eq, "US"}
             ])

    assert {:ok, %Bandera.Flag{}} = Bandera.get_flag(:"bandera_segment:premium_us")
  end

  test "a flag referencing a segment is enabled only for matching contexts" do
    {:ok, _} =
      Bandera.put_segment(:premium_us, [{"plan", :eq, "premium"}, {"country", :eq, "US"}])

    {:ok, _} = Bandera.enable(:new_billing, for_segment: :premium_us)

    assert Bandera.enabled?(:new_billing, context: %{"plan" => "premium", "country" => "US"})
    refute Bandera.enabled?(:new_billing, context: %{"plan" => "free", "country" => "US"})
  end

  test "clear(for_segment:) removes one segment gate" do
    {:ok, _} = Bandera.enable(:dash, for_segment: "premium")
    {:ok, _} = Bandera.enable(:dash, for_segment: "beta")

    assert :ok = Bandera.clear(:dash, for_segment: "premium")
    {:ok, flag} = Bandera.get_flag(:dash)
    names = for g <- flag.gates, Bandera.Gate.segment?(g), do: g.for
    assert names == ["beta"]
  end
end
