defmodule Bandera.PrerequisitesTest do
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

  test "a flag with a prerequisite is only enabled when the parent is enabled" do
    {:ok, _} = Bandera.enable(:child, requires: :parent)
    {:ok, _} = Bandera.enable(:child)
    refute Bandera.enabled?(:child)

    {:ok, _} = Bandera.enable(:parent)
    assert Bandera.enabled?(:child)
  end

  test "requires: {parent, false} requires the parent to be disabled" do
    {:ok, _} = Bandera.enable(:child, requires: {:parent, false})
    {:ok, _} = Bandera.enable(:child)

    # parent absent (disabled) -> prerequisite met
    assert Bandera.enabled?(:child)

    # parent enabled -> prerequisite not met
    {:ok, _} = Bandera.enable(:parent)
    refute Bandera.enabled?(:child)
  end

  test "prerequisite cycles resolve to false instead of looping" do
    {:ok, _} = Bandera.enable(:a, requires: :b)
    {:ok, _} = Bandera.enable(:a)
    {:ok, _} = Bandera.enable(:b, requires: :a)
    {:ok, _} = Bandera.enable(:b)
    refute Bandera.enabled?(:a)
  end

  test "a multi-level prerequisite chain requires every ancestor to be enabled" do
    {:ok, _} = Bandera.enable(:a, requires: :b)
    {:ok, _} = Bandera.enable(:a)
    {:ok, _} = Bandera.enable(:b, requires: :c)
    {:ok, _} = Bandera.enable(:b)

    # c not enabled yet -> b's prerequisite fails -> a fails transitively
    refute Bandera.enabled?(:a)

    {:ok, _} = Bandera.enable(:c)
    assert Bandera.enabled?(:a)
  end

  test "a prerequisite composes with a context rule on the child's own grant" do
    {:ok, _} = Bandera.enable(:parent)
    {:ok, _} = Bandera.enable(:billing, requires: :parent)
    {:ok, _} = Bandera.enable(:billing, when: [{"plan", :eq, "premium"}])

    # prerequisite met AND context matches
    assert Bandera.enabled?(:billing, context: %{"plan" => "premium"})
    # context misses -> not enabled even though prerequisite is met
    refute Bandera.enabled?(:billing, context: %{"plan" => "free"})

    # prerequisite vetoes regardless of context once the parent is off
    {:ok, _} = Bandera.disable(:parent)
    refute Bandera.enabled?(:billing, context: %{"plan" => "premium"})
  end

  test "clear(requires:) removes one prerequisite gate" do
    {:ok, _} = Bandera.enable(:child, requires: :parent_a)
    {:ok, _} = Bandera.enable(:child, requires: :parent_b)

    assert :ok = Bandera.clear(:child, requires: :parent_a)
    {:ok, flag} = Bandera.get_flag(:child)
    parents = for g <- flag.gates, Bandera.Gate.prerequisite?(g), do: g.for
    assert parents == [:parent_b]
  end
end
