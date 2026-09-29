defmodule Bandera.Dashboard.StaleTest do
  use ExUnit.Case, async: false

  alias Bandera.Dashboard.Stale

  describe "usage_available?/0" do
    test "returns false when Bandera.Usage is not running" do
      refute Stale.usage_available?(Bandera)
    end

    test "returns true when Bandera.Usage is running" do
      start_supervised!(Bandera.Usage)
      assert Stale.usage_available?(Bandera)
    end
  end

  describe "usage_status/0" do
    test "GIVEN Usage is stopped WHEN status is checked THEN it is unavailable" do
      assert Stale.usage_status(Bandera) == :unavailable
    end

    test "GIVEN in-memory usage is running WHEN status is checked THEN it is ready" do
      start_supervised!(Bandera.Usage)
      assert Stale.usage_status(Bandera) == :ready
    end

    test "GIVEN persisted history is loading WHEN status is checked THEN it is loading" do
      start_supervised!(Bandera.Usage)
      :sys.replace_state(Bandera.Usage, fn state -> %{state | loaded?: false} end)

      assert Stale.usage_status(Bandera) == :loading
    end
  end

  describe "stale_set/1" do
    test "returns empty MapSet when Usage is not running" do
      assert Stale.stale_set(Bandera) == MapSet.new()
    end

    test "returns empty MapSet when all flags have been recently evaluated" do
      setup_store()
      start_supervised!(Bandera.Usage)
      :ets.insert(Bandera.Usage, {:my_flag, DateTime.utc_now()})
      result = Stale.stale_set(Bandera, older_than: 30)
      refute MapSet.member?(result, :my_flag)
    end

    test "returns flag in MapSet when it was last evaluated beyond the threshold" do
      setup_store()
      {:ok, true} = Bandera.enable(:old_flag)
      start_supervised!(Bandera.Usage)
      old_time = DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)
      :ets.insert(Bandera.Usage, {:old_flag, old_time})
      result = Stale.stale_set(Bandera, older_than: 30)
      assert MapSet.member?(result, :old_flag)
    end

    test "GIVEN history is loading WHEN stale flags are requested THEN no flag is marked stale" do
      setup_store()
      {:ok, true} = Bandera.enable(:unseen_flag)
      start_supervised!(Bandera.Usage)
      :sys.replace_state(Bandera.Usage, fn state -> %{state | loaded?: false} end)

      assert Stale.stale_set(Bandera, older_than: 30) == MapSet.new()
    end
  end

  describe "age_days/1" do
    test "returns :never when flag has never been evaluated" do
      start_supervised!(Bandera.Usage)
      assert Stale.age_days(Bandera, :nonexistent_flag) == :never
    end

    test "returns {:ok, days} with correct floor when flag has been evaluated" do
      start_supervised!(Bandera.Usage)
      past = DateTime.add(DateTime.utc_now(), -5 * 86_400 - 3600, :second)
      :ets.insert(Bandera.Usage, {:some_flag, past})
      assert Stale.age_days(Bandera, :some_flag) == {:ok, 5}
    end

    test "returns :never when Usage is not running" do
      assert Stale.age_days(Bandera, :any_flag) == :never
    end

    test "clamps future timestamps to 0 days" do
      start_supervised!(Bandera.Usage)
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      :ets.insert(Bandera.Usage, {:future_flag, future})
      assert Stale.age_days(Bandera, :future_flag) == {:ok, 0}
    end
  end

  describe "for a named instance" do
    @named :dashboard_stale_named

    setup do
      start_supervised!(
        {Bandera, name: @named, persistence: [adapter: Bandera.Store.Persistent.Memory]}
      )

      :ok
    end

    test "usage_available?/1 and usage_status/1 are false/:unavailable until its own tracker runs" do
      refute Stale.usage_available?(@named)
      assert Stale.usage_status(@named) == :unavailable

      start_supervised!({Bandera.Usage, instance: @named})
      assert Stale.usage_available?(@named)
      assert Stale.usage_status(@named) == :ready
    end

    test "stale_set/2 and age_days/2 are scoped to the instance's own tracker" do
      {:ok, true} = Bandera.enable(:named_fresh, instance: @named)
      {:ok, true} = Bandera.enable(:named_stale, instance: @named)
      start_supervised!({Bandera.Usage, instance: @named})

      old_time = DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)
      :ets.insert(Bandera.Config.get(@named).usage_server, {:named_stale, old_time})
      :ets.insert(Bandera.Config.get(@named).usage_server, {:named_fresh, DateTime.utc_now()})

      result = Stale.stale_set(@named, older_than: 30)
      assert MapSet.member?(result, :named_stale)
      refute MapSet.member?(result, :named_fresh)

      assert Stale.age_days(@named, :named_stale) == {:ok, 40}
      # Reading against the wrong (default) instance's tracker, which isn't
      # running, must report :never rather than reaching into @named's data.
      assert Stale.age_days(Bandera, :named_stale) == :never
    end
  end

  defp setup_store do
    start_supervised!(Bandera.Store.Persistent.Memory)
    start_supervised!(Bandera.Store.Cache)
    Application.put_env(:bandera, :cache, enabled: true, ttl: 900)
    Application.put_env(:bandera, :persistence, adapter: Bandera.Store.Persistent.Memory)
    Application.put_env(:bandera, :store, Bandera.Store.TwoLevel)
    Bandera.reload_config()

    on_exit(fn ->
      Application.delete_env(:bandera, :cache)
      Application.delete_env(:bandera, :persistence)
      Application.delete_env(:bandera, :store)
      Bandera.reload_config()
    end)
  end
end
