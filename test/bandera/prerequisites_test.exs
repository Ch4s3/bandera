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

  test "prerequisite cycles resolve to false instead of looping" do
    {:ok, _} = Bandera.enable(:a, requires: :b)
    {:ok, _} = Bandera.enable(:a)
    {:ok, _} = Bandera.enable(:b, requires: :a)
    {:ok, _} = Bandera.enable(:b)
    refute Bandera.enabled?(:a)
  end
end
