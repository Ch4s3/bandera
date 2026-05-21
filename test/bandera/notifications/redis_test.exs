defmodule Bandera.Notifications.RedisTest do
  use ExUnit.Case, async: false
  @moduletag :redis

  alias Bandera.Flag
  alias Bandera.Notifications.Redis, as: RedisNotifier
  alias Bandera.Store.Cache

  @channel "bandera:changes"

  setup do
    start_supervised!(Cache)
    Application.put_env(:bandera, :cache, enabled: true, ttl: 900)

    Application.put_env(:bandera, :cache_bust_notifications,
      enabled: true,
      adapter: RedisNotifier
    )

    Bandera.reload_config()
    start_supervised!(RedisNotifier)
    wait_until(fn -> RedisNotifier.subscribed?() end)

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
    assert {:ok, _} = Cache.get(:f)

    {:ok, pub} = Redix.start_link()
    Redix.command(pub, ["PUBLISH", @channel, "some-other-node-id:f"])

    wait_until(fn -> match?({:miss, _}, Cache.get(:f)) end)
  end

  test "our own change is ignored (cache not busted)" do
    Cache.put(Flag.new(:f, []))
    :ok = RedisNotifier.publish_change(:f)
    Process.sleep(100)
    assert {:ok, _} = Cache.get(:f)
  end

  test "unique_id/0 returns a stable string id" do
    id = RedisNotifier.unique_id()
    assert is_binary(id)
    assert RedisNotifier.unique_id() == id
  end

  test "child_spec/1 returns a supervisable spec" do
    assert %{
             id: Bandera.Notifications.Redis,
             start: {Bandera.Notifications.Redis, :start_link, [_]}
           } = Bandera.Notifications.Redis.child_spec([])
  end
end
