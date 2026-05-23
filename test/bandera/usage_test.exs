defmodule Bandera.UsageTest do
  use ExUnit.Case, async: false
  alias Bandera.Store.Cache
  alias Bandera.Store.Persistent.Memory
  alias Bandera.Usage

  setup do
    start_supervised!(Memory)
    start_supervised!(Cache)
    start_supervised!(Usage)
    Application.put_env(:bandera, :cache, enabled: true, ttl: 900)
    Application.put_env(:bandera, :persistence, adapter: Memory)
    Application.put_env(:bandera, :store, Bandera.Store.TwoLevel)
    Bandera.reload_config()
    :ok = Usage.attach()

    on_exit(fn ->
      Usage.detach()
      Application.delete_env(:bandera, :cache)
      Application.delete_env(:bandera, :persistence)
      Application.delete_env(:bandera, :store)
      Bandera.reload_config()
    end)

    :ok
  end

  test "records the last time a flag was evaluated via [:bandera, :enabled?]" do
    refute Usage.last_evaluated(:never_checked)

    :telemetry.execute([:bandera, :enabled?], %{system_time: 1}, %{
      flag_name: :checked,
      options: [],
      result: false
    })

    assert %DateTime{} = Usage.last_evaluated(:checked)
  end

  test "records variant resolutions via [:bandera, :variant]" do
    refute Usage.last_evaluated(:hero)

    :telemetry.execute([:bandera, :variant], %{system_time: 1}, %{
      flag_name: :hero,
      options: [for: %{id: 1}],
      result: "blue"
    })

    assert %DateTime{} = Usage.last_evaluated(:hero)
  end

  test "last_evaluated returns nil when the tracker is not running" do
    :ok = stop_supervised(Usage)
    assert Usage.last_evaluated(:anything) == nil
  end

  test "stale_flags returns flags not evaluated within the window" do
    {:ok, _} = Bandera.enable(:fresh)
    {:ok, _} = Bandera.enable(:old)

    # mark :fresh as just-evaluated; leave :old with old usage
    :ets.insert(Usage, {:fresh, DateTime.utc_now()})
    :ets.insert(Usage, {:old, DateTime.add(DateTime.utc_now(), -100, :day)})

    assert :old in Bandera.stale_flags(older_than: 30)
    refute :fresh in Bandera.stale_flags(older_than: 30)
  end

  test "a flag resolved via Bandera.variant/2 is recorded and not reported stale" do
    {:ok, _} = Bandera.put_variants(:hero, %{"a" => 1, "b" => 1})

    assert Bandera.variant(:hero, for: %{id: 1}) in ["a", "b"]

    assert %DateTime{} = Usage.last_evaluated(:hero)
    refute :hero in Bandera.stale_flags(older_than: 30)
  end

  test "mix bandera.flags --stale prints stale flag names" do
    import ExUnit.CaptureIO

    {:ok, _} = Bandera.enable(:old)
    :ets.insert(Usage, {:old, DateTime.add(DateTime.utc_now(), -100, :day)})

    output = capture_io(fn -> Mix.Tasks.Bandera.Flags.run(["--stale", "--older-than", "30"]) end)
    assert output =~ "old"
  end
end
