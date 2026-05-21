defmodule Bandera.ConfigTest do
  use ExUnit.Case, async: false
  alias Bandera.Config

  setup do
    original = Application.get_all_env(:bandera)

    on_exit(fn ->
      for {k, _} <- Application.get_all_env(:bandera), do: Application.delete_env(:bandera, k)
      for {k, v} <- original, do: Application.put_env(:bandera, k, v)
      Config.reload()
    end)

    :ok
  end

  test "defaults: cache enabled, ttl 900, memory adapter, two-level store" do
    for {k, _} <- Application.get_all_env(:bandera), do: Application.delete_env(:bandera, k)
    Config.reload()

    assert Config.cache_enabled?() == true
    assert Config.cache_ttl() == 900
    assert Config.persistence_adapter() == Bandera.Store.Persistent.Memory
    assert Config.store() == Bandera.Store.TwoLevel
  end

  test "reload/0 picks up runtime changes without recompilation" do
    Application.put_env(:bandera, :cache, enabled: false, ttl: 5)
    Config.reload()

    assert Config.cache_enabled?() == false
    assert Config.cache_ttl() == 5
  end

  test "snapshot/0 lazily seeds persistent_term from defaults when missing" do
    Application.delete_env(:bandera, :cache)
    :persistent_term.erase({Config, :snapshot})

    assert is_map(Config.snapshot())
    assert Config.cache_enabled?() == true
    assert Config.cache_ttl() == 900
  end
end
