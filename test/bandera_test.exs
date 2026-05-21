defmodule BanderaTest do
  use ExUnit.Case, async: false
  alias Bandera.Store.Cache
  alias Bandera.Store.Persistent.Memory

  doctest Bandera

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

  test "boolean enable/disable/enabled?" do
    refute Bandera.enabled?(:f)
    assert {:ok, true} = Bandera.enable(:f)
    assert Bandera.enabled?(:f)
    assert {:ok, false} = Bandera.disable(:f)
    refute Bandera.enabled?(:f)
  end

  test "per-actor enable" do
    assert {:ok, true} = Bandera.enable(:f, for_actor: %{id: 1})
    assert Bandera.enabled?(:f, for: %{id: 1})
    refute Bandera.enabled?(:f, for: %{id: 2})
  end

  test "per-group enable" do
    assert {:ok, true} = Bandera.enable(:f, for_group: :admin)
    assert Bandera.enabled?(:f, for: %{id: 1, groups: [:admin]})
    refute Bandera.enabled?(:f, for: %{id: 2, groups: [:staff]})
  end

  test "percentage_of_actors enable" do
    assert {:ok, true} = Bandera.enable(:f, for_percentage_of: {:actors, 0.999999})
    assert Bandera.enabled?(:f, for: %{id: 1})
  end

  test "disable for_percentage_of inverts the ratio" do
    assert {:ok, false} = Bandera.disable(:f, for_percentage_of: {:actors, 0.999999})
    # inverted ratio ~0.000001 -> almost everyone is disabled
    refute Bandera.enabled?(:f, for: %{id: 1})
  end

  test "clear/2 removes one gate (leaving others); clear/1 removes the whole flag" do
    {:ok, _} = Bandera.enable(:f)
    {:ok, _} = Bandera.disable(:f, for_actor: %{id: 1})
    # actor gate disables id:1 even though boolean is enabled
    refute Bandera.enabled?(:f, for: %{id: 1})

    # clearing the actor gate leaves the boolean gate -> id:1 now follows boolean (true)
    assert :ok = Bandera.clear(:f, for_actor: %{id: 1})
    assert Bandera.enabled?(:f, for: %{id: 1})
    assert Bandera.enabled?(:f)

    # clearing the whole flag disables it entirely
    assert :ok = Bandera.clear(:f)
    refute Bandera.enabled?(:f)
  end

  test "all_flag_names and all_flags" do
    {:ok, _} = Bandera.enable(:a)
    {:ok, _} = Bandera.enable(:b)
    assert {:ok, names} = Bandera.all_flag_names()
    assert Enum.sort(names) == [:a, :b]
    assert {:ok, flags} = Bandera.all_flags()
    assert length(flags) == 2
  end

  test "get_flag returns the stored flag" do
    {:ok, _} = Bandera.enable(:a)
    assert {:ok, %Bandera.Flag{name: :a}} = Bandera.get_flag(:a)
  end

  test "get_flag returns an empty flag (not an error) for an unknown name" do
    assert {:ok, %Bandera.Flag{name: :never_set, gates: []}} = Bandera.get_flag(:never_set)
  end

  test "enable for_percentage_of {:time, ratio} stores a percentage_of_time gate" do
    assert {:ok, true} = Bandera.enable(:f, for_percentage_of: {:time, 0.5})

    assert {:ok, %Bandera.Flag{gates: [%Bandera.Gate{type: :percentage_of_time, for: 0.5}]}} =
             Bandera.get_flag(:f)
  end

  test "clear(boolean: true) removes only the boolean gate" do
    {:ok, _} = Bandera.enable(:f)
    {:ok, _} = Bandera.enable(:f, for_actor: %{id: 1})

    assert :ok = Bandera.clear(:f, boolean: true)
    # boolean gate gone, actor gate remains
    assert Bandera.enabled?(:f, for: %{id: 1})
    refute Bandera.enabled?(:f)
  end

  test "clear(for_percentage: true) clears a percentage_of_actors gate (shared slot)" do
    {:ok, _} = Bandera.enable(:f, for_percentage_of: {:actors, 0.999999})
    assert Bandera.enabled?(:f, for: %{id: 1})

    assert :ok = Bandera.clear(:f, for_percentage: true)
    refute Bandera.enabled?(:f, for: %{id: 1})
  end

  test "enabled?(flag, for: nil) behaves like enabled?(flag)" do
    {:ok, _} = Bandera.enable(:f)
    assert Bandera.enabled?(:f, for: nil) == Bandera.enabled?(:f)
    assert Bandera.enabled?(:f, for: nil)
  end

  test "enable(flag, for_actor: nil) behaves like a flag-wide enable" do
    assert {:ok, true} = Bandera.enable(:f, for_actor: nil)
    assert Bandera.enabled?(:f)
    assert Bandera.enabled?(:f, for: %{id: 7})
  end

  test "enable(flag, for_group: nil) behaves like a flag-wide enable" do
    assert {:ok, true} = Bandera.enable(:f, for_group: nil)
    assert Bandera.enabled?(:f)
    assert Bandera.enabled?(:f, for: %{id: 7, groups: [:anything]})
  end

  test "disable(flag, for_actor: actor) disables only that actor" do
    {:ok, _} = Bandera.enable(:f)
    assert {:ok, false} = Bandera.disable(:f, for_actor: %{id: 1})
    refute Bandera.enabled?(:f, for: %{id: 1})
    # other actors still follow the flag-wide boolean (true)
    assert Bandera.enabled?(:f, for: %{id: 2})
  end

  test "disable(flag, for_group: name) disables only that group" do
    {:ok, _} = Bandera.enable(:f)
    assert {:ok, false} = Bandera.disable(:f, for_group: :admin)
    refute Bandera.enabled?(:f, for: %{id: 1, groups: [:admin]})
    assert Bandera.enabled?(:f, for: %{id: 2, groups: [:staff]})
  end

  test "disable(flag, for_actor: nil) behaves like a flag-wide disable" do
    {:ok, _} = Bandera.enable(:f)
    assert Bandera.enabled?(:f)
    assert {:ok, false} = Bandera.disable(:f, for_actor: nil)
    refute Bandera.enabled?(:f)
  end

  test "disable(flag, for_group: nil) behaves like a flag-wide disable" do
    {:ok, _} = Bandera.enable(:f)
    assert Bandera.enabled?(:f)
    assert {:ok, false} = Bandera.disable(:f, for_group: nil)
    refute Bandera.enabled?(:f)
  end

  test "clear(flag, for_group: name) removes only that group gate" do
    {:ok, _} = Bandera.enable(:f)
    {:ok, _} = Bandera.disable(:f, for_group: :admin)
    refute Bandera.enabled?(:f, for: %{id: 1, groups: [:admin]})

    assert :ok = Bandera.clear(:f, for_group: :admin)
    # group gate gone, boolean (true) remains -> admins now enabled again
    assert Bandera.enabled?(:f, for: %{id: 1, groups: [:admin]})
    assert Bandera.enabled?(:f)
  end

  test "clear(flag, for_actor: nil) clears the whole flag" do
    {:ok, _} = Bandera.enable(:f)
    assert Bandera.enabled?(:f)
    assert :ok = Bandera.clear(:f, for_actor: nil)
    refute Bandera.enabled?(:f)
    assert {:ok, %Bandera.Flag{name: :f, gates: []}} = Bandera.get_flag(:f)
  end

  test "clear(flag, for_group: nil) clears the whole flag" do
    {:ok, _} = Bandera.enable(:f)
    assert Bandera.enabled?(:f)
    assert :ok = Bandera.clear(:f, for_group: nil)
    refute Bandera.enabled?(:f)
    assert {:ok, %Bandera.Flag{name: :f, gates: []}} = Bandera.get_flag(:f)
  end

  describe "store errors propagate (FailingStore)" do
    setup do
      Application.put_env(:bandera, :store, Bandera.FailingStore)
      Bandera.reload_config()
      :ok
    end

    test "enabled? logs and returns false when the store lookup fails" do
      import ExUnit.CaptureLog

      assert capture_log(fn -> refute Bandera.enabled?(:f) end) =~ "store lookup"
      assert capture_log(fn -> refute Bandera.enabled?(:f, for: %{id: 1}) end) =~ "store lookup"
    end

    test "enable/disable return the store error" do
      assert {:error, :boom} = Bandera.enable(:f)
      assert {:error, :boom} = Bandera.enable(:f, for_actor: %{id: 1})
      assert {:error, :boom} = Bandera.enable(:f, for_group: :admin)
      assert {:error, :boom} = Bandera.disable(:f)
    end

    test "clear returns the store error" do
      assert {:error, :boom} = Bandera.clear(:f)
      assert {:error, :boom} = Bandera.clear(:f, for_actor: %{id: 1})
    end

    test "disable for_percentage_of returns the store error from the underlying enable" do
      assert {:error, :boom} = Bandera.disable(:f, for_percentage_of: {:actors, 0.5})
    end

    test "all_flags and all_flag_names return the store error" do
      assert {:error, :boom} = Bandera.all_flags()
      assert {:error, :boom} = Bandera.all_flag_names()
    end
  end
end
