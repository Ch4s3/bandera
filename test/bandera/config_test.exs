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

  test "notifications default to disabled with the Redis adapter" do
    for {k, _} <- Application.get_all_env(:bandera), do: Application.delete_env(:bandera, k)
    Config.reload()

    assert Config.notifications_enabled?() == false
    assert Config.notifications_adapter() == Bandera.Notifications.Redis
  end

  test "build_unique_id/0 returns distinct lowercase-hex ids" do
    a = Config.build_unique_id()
    b = Config.build_unique_id()
    assert a =~ ~r/\A[0-9a-f]+\z/
    assert a != b
    assert String.length(a) == 16
  end

  test "group_separator defaults to \"_\"" do
    Application.delete_env(:bandera, :dashboard)
    Config.reload()
    assert Config.group_separator() == "_"
  end

  test "group_separator can be overridden to \"/\"" do
    Application.put_env(:bandera, :dashboard, group_separator: "/")
    Config.reload()
    assert Config.group_separator() == "/"
  end

  test "group_separator can be overridden to nil" do
    Application.put_env(:bandera, :dashboard, group_separator: nil)
    Config.reload()
    assert Config.group_separator() == nil
  end

  test "theme defaults to :standalone" do
    Application.delete_env(:bandera, :dashboard)
    Config.reload()
    assert Config.theme() == :standalone
  end

  test "theme can be set to :daisyui" do
    Application.put_env(:bandera, :dashboard, theme: :daisyui)
    Config.reload()
    assert Config.theme() == :daisyui
  end

  test "an unknown theme falls back to :standalone" do
    Application.put_env(:bandera, :dashboard, theme: :neon)
    Config.reload()
    assert Config.theme() == :standalone
  end
end
