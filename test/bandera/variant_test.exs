defmodule Bandera.VariantTest do
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

  test "put_variants then variant resolves a sticky per-actor variation" do
    assert {:ok, %Bandera.Flag{}} = Bandera.put_variants(:hero, %{"a" => 1, "b" => 1})

    v = Bandera.variant(:hero, for: %{id: 42})
    assert v in ["a", "b"]
    assert Bandera.variant(:hero, for: %{id: 42}) == v
  end

  test "variant returns :default when the flag is unset" do
    assert Bandera.variant(:missing, for: %{id: 1}, default: "control") == "control"
  end

  test "variant returns :default (nil) when no default is given and flag is unset" do
    assert Bandera.variant(:missing, for: %{id: 1}) == nil
  end
end
