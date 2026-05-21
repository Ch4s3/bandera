defmodule Bandera.Notifications.PhoenixPubSubTest do
  use ExUnit.Case, async: false

  alias Bandera.Flag
  alias Bandera.Notifications.PhoenixPubSub, as: PubSubNotifier
  alias Bandera.Store.Cache

  setup do
    start_supervised!({Phoenix.PubSub, name: Bandera.Test.PubSub})
    start_supervised!(Cache)
    Application.put_env(:bandera, :cache, enabled: true, ttl: 900)

    Application.put_env(:bandera, :cache_bust_notifications,
      enabled: true,
      adapter: PubSubNotifier,
      client: Bandera.Test.PubSub
    )

    Bandera.reload_config()
    start_supervised!(PubSubNotifier)

    on_exit(fn ->
      Application.delete_env(:bandera, :cache)
      Application.delete_env(:bandera, :cache_bust_notifications)
      Bandera.reload_config()
    end)

    :ok
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition not met in time")

      true ->
        Process.sleep(20)
        wait_until(fun, tries - 1)
    end
  end

  test "a foreign change busts the local cache entry" do
    Cache.put(Flag.new(:f, []))

    Phoenix.PubSub.broadcast(
      Bandera.Test.PubSub,
      "bandera:changes",
      {:bandera_change, :f, "other-node"}
    )

    wait_until(fn -> match?({:miss, _}, Cache.get(:f)) end)
  end

  test "our own change is ignored" do
    Cache.put(Flag.new(:f, []))
    :ok = PubSubNotifier.publish_change(:f)
    Process.sleep(100)
    assert {:ok, _} = Cache.get(:f)
  end

  test "unique_id/0 returns a stable string id" do
    id = PubSubNotifier.unique_id()
    assert is_binary(id)
    assert PubSubNotifier.unique_id() == id
  end
end
