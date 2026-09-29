defmodule Bandera.TestTest do
  # async: false — these tests set the global store config (:persistent_term snapshot)
  # and start/stop named instances.
  use ExUnit.Case, async: false

  # Configure the process-scoped store BEFORE `use Bandera.Test` so its setup
  # (which applies @tag feature_flags via the public API) sees the right store.
  setup do
    Application.put_env(:bandera, :store, Bandera.Store.ProcessScoped)
    Bandera.reload_config()

    on_exit(fn ->
      Application.delete_env(:bandera, :store)
      Bandera.reload_config()
    end)

    :ok
  end

  use Bandera.Test

  test "enable_flag / disable_flag toggle through the public API" do
    refute Bandera.enabled?(:beta)
    assert :ok = enable_flag(:beta)
    assert Bandera.enabled?(:beta)
    assert :ok = disable_flag(:beta)
    refute Bandera.enabled?(:beta)
  end

  test "enable_flag/2 targets a specific actor" do
    assert :ok = enable_flag(:beta, %{id: 1})
    assert Bandera.enabled?(:beta, for: %{id: 1})
    refute Bandera.enabled?(:beta, for: %{id: 2})
  end

  test "put_flag/2 sets a boolean value directly" do
    assert :ok = Bandera.Test.put_flag(:gamma, true)
    assert Bandera.enabled?(:gamma)
  end

  test "enable_flag/2 enables only the given actor" do
    assert :ok = enable_flag(:beta, %{id: 1})
    assert Bandera.enabled?(:beta, for: %{id: 1})
    refute Bandera.enabled?(:beta, for: %{id: 2})
  end

  test "disable_flag/1 turns a flag off" do
    assert :ok = enable_flag(:beta)
    assert Bandera.enabled?(:beta)
    assert :ok = disable_flag(:beta)
    refute Bandera.enabled?(:beta)
  end

  test "disable_flag/2 disables a flag for a specific actor" do
    assert :ok = enable_flag(:beta)
    assert :ok = disable_flag(:beta, %{id: 1})
    refute Bandera.enabled?(:beta, for: %{id: 1})
    # other actors still follow the flag-wide boolean (true)
    assert Bandera.enabled?(:beta, for: %{id: 2})
  end

  test "put_flag/3 sets a boolean value for a specific actor" do
    assert :ok = enable_flag(:gamma)
    assert :ok = Bandera.Test.put_flag(:gamma, false, %{id: 1})
    refute Bandera.enabled?(:gamma, for: %{id: 1})
    assert Bandera.enabled?(:gamma, for: %{id: 2})
  end

  @tag feature_flags: [tagged_on: true, tagged_off: false]
  test "@tag feature_flags applies declared flags before the test body" do
    assert Bandera.enabled?(:tagged_on)
    refute Bandera.enabled?(:tagged_off)
  end

  test "reset/0 clears the current process's overrides" do
    assert :ok = enable_flag(:to_clear)
    assert Bandera.enabled?(:to_clear)
    assert :ok = Bandera.Test.reset()
    refute Bandera.enabled?(:to_clear)
  end

  test "writes do not escape the process (no DB/PubSub) — unrelated process is unaffected" do
    enable_flag(:scoped)
    parent = self()
    spawn(fn -> send(parent, {:enabled?, Bandera.enabled?(:scoped)}) end)
    assert_receive {:enabled?, false}
  end

  test "clear/1 removes a single flag's overrides, leaving others intact" do
    enable_flag(:keep)
    enable_flag(:drop_me)

    assert :ok = Bandera.Test.clear(:drop_me)
    refute Bandera.enabled?(:drop_me)
    assert Bandera.enabled?(:keep)
  end

  test "start/0 is idempotent when the ownership server is already running" do
    # test_helper.exs already started it; calling again must be a no-op, not crash.
    assert :ok = Bandera.Test.start()
  end

  test "put_flag raises when the underlying store returns an error" do
    Application.put_env(:bandera, :store, Bandera.FailingStore)
    Bandera.reload_config()

    on_exit(fn ->
      Application.put_env(:bandera, :store, Bandera.Store.ProcessScoped)
      Bandera.reload_config()
    end)

    assert_raise RuntimeError, ~r/unexpected store error/, fn ->
      Bandera.Test.put_flag(:boom, true)
    end
  end

  describe "put_flag/4, clear/2, and reset/0 across named instances" do
    setup do
      start_supervised!({Bandera, name: :test_inst_a, store: Bandera.Store.ProcessScoped})
      start_supervised!({Bandera, name: :test_inst_b, store: Bandera.Store.ProcessScoped})
      :ok
    end

    test "put_flag/4 scopes a boolean override to the given instance" do
      :ok = Bandera.Test.put_flag(:x, true, nil, instance: :test_inst_a)
      assert Bandera.enabled?(:x, instance: :test_inst_a)
      refute Bandera.enabled?(:x, instance: :test_inst_b)
    end

    test "put_flag/4 scopes an actor override to the given instance" do
      :ok = Bandera.Test.put_flag(:x, true, %{id: 1}, instance: :test_inst_b)
      assert Bandera.enabled?(:x, for: %{id: 1}, instance: :test_inst_b)
      refute Bandera.enabled?(:x, for: %{id: 1}, instance: :test_inst_a)
    end

    test "clear/2 removes overrides from only the given instance" do
      :ok = Bandera.Test.put_flag(:y, true, nil, instance: :test_inst_a)
      :ok = Bandera.Test.put_flag(:y, true, nil, instance: :test_inst_b)

      assert :ok = Bandera.Test.clear(:y, instance: :test_inst_a)
      refute Bandera.enabled?(:y, instance: :test_inst_a)
      assert Bandera.enabled?(:y, instance: :test_inst_b)
    end

    test "reset/0 clears the current process's overrides for every instance" do
      :ok = Bandera.Test.put_flag(:z, true, nil, instance: :test_inst_a)
      :ok = Bandera.Test.put_flag(:z, true, nil, instance: :test_inst_b)
      assert Bandera.enabled?(:z, instance: :test_inst_a)
      assert Bandera.enabled?(:z, instance: :test_inst_b)

      assert :ok = Bandera.Test.reset()
      refute Bandera.enabled?(:z, instance: :test_inst_a)
      refute Bandera.enabled?(:z, instance: :test_inst_b)
    end

    test "a named instance's overrides are inherited by spawned Tasks via $callers" do
      :ok = Bandera.Test.put_flag(:w, true, nil, instance: :test_inst_a)
      task = Task.async(fn -> Bandera.enabled?(:w, instance: :test_inst_a) end)
      assert Task.await(task)
    end

    test "a named instance's overrides are cleaned up when the owning process exits" do
      key = {:flags, :test_inst_a}

      owner =
        spawn(fn ->
          Bandera.Test.put_flag(:transient, true, nil, instance: :test_inst_a)
          Process.sleep(:infinity)
        end)

      assert wait_until(fn ->
               match?(
                 {:ok, ^owner},
                 NimbleOwnership.fetch_owner(Bandera.Store.ProcessScoped, [owner], key)
               )
             end)

      ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, _}

      assert wait_until(fn ->
               NimbleOwnership.fetch_owner(Bandera.Store.ProcessScoped, [owner], key) == :error
             end)
    end
  end

  defp wait_until(fun, timeout \\ 1_000) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(10) && wait_until(fun, timeout - 10)
    end
  end
end

defmodule Bandera.TestTest.InstanceFacade do
  @moduledoc false
  use Bandera
end

defmodule Bandera.TestTest.NamedInstanceHelpersTest do
  # async: false — starts named instances backed by the process-scoped store.
  use ExUnit.Case, async: false

  # Registered before `use Bandera.Test` so the instance is running before that
  # macro's own `feature_flags` setup callback runs (setups run in call order).
  setup do
    start_supervised!({Bandera.TestTest.InstanceFacade, store: Bandera.Store.ProcessScoped})
    start_supervised!({Bandera, name: :facade_sibling, store: Bandera.Store.ProcessScoped})
    :ok
  end

  use Bandera.Test, instance: Bandera.TestTest.InstanceFacade

  test "enable_flag/1 and disable_flag/1 target only the bound instance" do
    enable_flag(:beta)
    assert Bandera.TestTest.InstanceFacade.enabled?(:beta)
    refute Bandera.enabled?(:beta, instance: :facade_sibling)

    disable_flag(:beta)
    refute Bandera.TestTest.InstanceFacade.enabled?(:beta)
  end

  test "enable_flag/2 and disable_flag/2 target a specific actor on the bound instance" do
    enable_flag(:beta, %{id: 1})
    assert Bandera.TestTest.InstanceFacade.enabled?(:beta, for: %{id: 1})
    refute Bandera.TestTest.InstanceFacade.enabled?(:beta, for: %{id: 2})

    disable_flag(:beta, %{id: 1})
    refute Bandera.TestTest.InstanceFacade.enabled?(:beta, for: %{id: 1})
  end

  @tag feature_flags: [tagged_on: true, tagged_off: false]
  test "@tag feature_flags applies declared flags to the bound instance only" do
    assert Bandera.TestTest.InstanceFacade.enabled?(:tagged_on)
    refute Bandera.TestTest.InstanceFacade.enabled?(:tagged_off)
    refute Bandera.enabled?(:tagged_on, instance: :facade_sibling)
  end
end
