defmodule Bandera.UsageTest do
  use ExUnit.Case, async: false
  alias Bandera.Store.Cache
  alias Bandera.Store.Persistent.Memory
  alias Bandera.Usage

  setup do
    start_supervised!(Memory)
    start_supervised!(Cache)
    Application.put_env(:bandera, :cache, enabled: true, ttl: 900)
    Application.put_env(:bandera, :persistence, adapter: Memory)
    Application.put_env(:bandera, :store, Bandera.Store.TwoLevel)
    Bandera.reload_config()
    start_supervised!(Usage)
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

  test "records the last time a flag was evaluated" do
    refute Usage.last_evaluated(:never_checked)

    :telemetry.execute([:bandera, :enabled?], %{system_time: 1}, %{
      flag_name: :checked,
      options: [],
      result: false
    })

    assert %DateTime{} = Usage.last_evaluated(:checked)
  end

  test "records usage through a real Bandera.enabled?/2 call" do
    {:ok, _} = Bandera.enable(:checked_via_api)
    refute Usage.last_evaluated(:checked_via_api)

    assert Bandera.enabled?(:checked_via_api)
    assert %DateTime{} = Usage.last_evaluated(:checked_via_api)
  end

  test "records usage when a flag is resolved via variant/2" do
    {:ok, _} = Bandera.put_variants(:hero, %{"a" => 1, "b" => 1})
    refute Usage.last_evaluated(:hero)

    _ = Bandera.variant(:hero, for: %{id: 1})
    assert %DateTime{} = Usage.last_evaluated(:hero)
  end

  test "stale_flags returns flags not evaluated within the window" do
    {:ok, _} = Bandera.enable(:fresh)
    {:ok, _} = Bandera.enable(:old)

    # mark :fresh as just-evaluated; leave :old with no/old usage
    :ets.insert(Bandera.Usage, {:fresh, DateTime.utc_now()})
    :ets.insert(Bandera.Usage, {:old, DateTime.add(DateTime.utc_now(), -100, :day)})

    assert :old in Bandera.stale_flags(older_than: 30)
    refute :fresh in Bandera.stale_flags(older_than: 30)
  end

  test "a negative older_than does not mark a freshly-evaluated flag as stale" do
    {:ok, _} = Bandera.enable(:fresh)
    # A clearly-recent evaluation (slightly ahead of now to avoid the now-boundary).
    :ets.insert(Bandera.Usage, {:fresh, DateTime.add(DateTime.utc_now(), 60, :second)})

    # Negative window previously made the cutoff a future date -> everything stale.
    refute :fresh in Bandera.stale_flags(older_than: -100)
  end

  test "stale_flags excludes internal segment definitions" do
    {:ok, _} = Bandera.put_segment(:premium, [{"plan", :eq, "premium"}])

    refute Enum.any?(Bandera.stale_flags(older_than: 30), fn name ->
             String.starts_with?(to_string(name), "bandera_segment:")
           end)
  end

  test "mix bandera.flags --stale prints stale flag names" do
    import ExUnit.CaptureIO
    {:ok, _} = Bandera.enable(:old)
    :ets.insert(Bandera.Usage, {:old, DateTime.add(DateTime.utc_now(), -100, :day)})

    output =
      capture_io(fn -> Mix.Tasks.Bandera.Flags.run(["--stale", "--older-than", "30"]) end)

    assert output =~ "old"
  end
end
