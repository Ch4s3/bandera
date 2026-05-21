defmodule Bandera.TestTest do
  # async: false — these tests set the global store config (:persistent_term snapshot).
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
end
