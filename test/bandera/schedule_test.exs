defmodule Bandera.ScheduleTest do
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

  test "enable(schedule:) gates by time window" do
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
    future = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_iso8601()
    assert {:ok, true} = Bandera.enable(:launch, schedule: {past, future})
    assert Bandera.enabled?(:launch)
  end

  test "schedule gate outside active window does not enable the flag" do
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
    assert {:ok, true} = Bandera.enable(:not_yet, schedule: {future, nil})
    refute Bandera.enabled?(:not_yet)
  end

  test "clear(schedule: true) removes the schedule gate" do
    {:ok, _} = Bandera.enable(:promo, schedule: {"2026-01-01T00:00:00Z", nil})
    {:ok, flag} = Bandera.get_flag(:promo)
    assert Enum.any?(flag.gates, &Bandera.Gate.schedule?/1)

    assert :ok = Bandera.clear(:promo, schedule: true)
    {:ok, flag} = Bandera.get_flag(:promo)
    refute Enum.any?(flag.gates, &Bandera.Gate.schedule?/1)
  end
end
