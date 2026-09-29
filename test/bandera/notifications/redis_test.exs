defmodule Bandera.Notifications.RedisTest do
  use ExUnit.Case, async: false
  @moduletag :redis

  alias Bandera.Config
  alias Bandera.Flag
  alias Bandera.Notifications
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

    %{conf: Config.get()}
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

  test "a foreign change busts the local cache entry", %{conf: conf} do
    Cache.put(conf, Flag.new(:f, []))
    assert {:ok, _} = Cache.get(conf, :f)

    {:ok, pub} = Redix.start_link()
    Redix.command(pub, ["PUBLISH", @channel, "some-other-node-id:f"])

    wait_until(fn -> match?({:miss, _}, Cache.get(conf, :f)) end)
  end

  test "our own change is ignored (cache not busted)", %{conf: conf} do
    Cache.put(conf, Flag.new(:f, []))
    :ok = RedisNotifier.publish_change(conf, :f)
    Process.sleep(100)
    assert {:ok, _} = Cache.get(conf, :f)
  end

  test "unique_id/1 returns a stable string id", %{conf: conf} do
    id = RedisNotifier.unique_id(conf)
    assert is_binary(id)
    assert RedisNotifier.unique_id(conf) == id
  end

  test "child_spec/1 returns a supervisable spec" do
    assert %{
             id: Bandera.Notifications.Redis,
             start: {Bandera.Notifications.Redis, :start_link, [_]}
           } = Bandera.Notifications.Redis.child_spec([])
  end

  test "the pre-instance arities act on the default instance's notifier", %{conf: conf} do
    assert RedisNotifier.unique_id() == RedisNotifier.unique_id(conf)
    assert :ok = RedisNotifier.publish_change(:legacy)
  end

  describe "multiple instances" do
    defp start_instance(name) do
      start_supervised!(
        {Bandera, name: name, cache_bust_notifications: [enabled: true, adapter: RedisNotifier]}
      )

      conf = Config.get(name)
      wait_until(fn -> RedisNotifier.subscribed?(name) end)
      conf
    end

    test "the default instance's channel is unchanged", %{conf: conf} do
      assert Notifications.topic(conf) == "bandera:changes"
    end

    test "child_spec/1 for a config scopes the id to the instance", %{conf: conf} do
      assert %{id: {Bandera.Notifications.Redis, name}} = RedisNotifier.child_spec(conf)
      assert name == conf.name
    end

    test "instances subscribe and publish on their own channel, isolated from each other" do
      a = start_instance(:redis_a)
      b = start_instance(:redis_b)

      assert Notifications.topic(a) == "bandera:{redis_a}:changes"
      assert Notifications.topic(b) == "bandera:{redis_b}:changes"

      Cache.put(a, Flag.new(:f, []))
      Cache.put(b, Flag.new(:f, []))

      {:ok, pub} = Redix.start_link()
      Redix.command(pub, ["PUBLISH", Notifications.topic(a), "other-node:f"])

      wait_until(fn -> match?({:miss, _}, Cache.get(a, :f)) end)

      # Fence: Redis delivers to a subscriber in publish order, so once b has handled
      # this later message on its own channel it would already have handled the one
      # on a's channel, had it (wrongly) been subscribed there.
      Cache.put(b, Flag.new(:fence, []))
      Redix.command(pub, ["PUBLISH", Notifications.topic(b), "other-node:fence"])
      wait_until(fn -> match?({:miss, _}, Cache.get(b, :fence)) end)

      # b never subscribed to a's channel, so its entry survives.
      assert {:ok, _} = Cache.get(b, :f)
    end

    test "enable/2 publishes only on the writing instance's own channel" do
      a = start_instance(:redis_a)
      b = start_instance(:redis_b)

      {:ok, sub} = Redix.PubSub.start_link()
      {:ok, ref} = Redix.PubSub.subscribe(sub, Notifications.topic(a), self())
      assert_receive {:redix_pubsub, ^sub, ^ref, :subscribed, _meta}
      {:ok, b_ref} = Redix.PubSub.subscribe(sub, Notifications.topic(b), self())
      assert_receive {:redix_pubsub, ^sub, ^b_ref, :subscribed, _meta}
      wait_until(fn -> RedisNotifier.subscribed?(:redis_a) end)

      {:ok, _} = Bandera.enable(:f, instance: :redis_a)

      assert_receive {:redix_pubsub, ^sub, _ref, :message,
                      %{channel: "bandera:{redis_a}:changes"}}

      refute_receive {:redix_pubsub, ^sub, _ref, :message,
                      %{channel: "bandera:{redis_b}:changes"}}
    end
  end
end
