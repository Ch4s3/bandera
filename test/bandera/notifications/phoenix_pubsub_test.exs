defmodule Bandera.Notifications.PhoenixPubSubTest do
  use ExUnit.Case, async: false

  alias Bandera.Config
  alias Bandera.Flag
  alias Bandera.Notifications
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

    Phoenix.PubSub.broadcast(
      Bandera.Test.PubSub,
      "bandera:changes",
      {:bandera_change, :f, "other-node"}
    )

    wait_until(fn -> match?({:miss, _}, Cache.get(conf, :f)) end)
  end

  test "our own change is ignored", %{conf: conf} do
    Cache.put(conf, Flag.new(:f, []))
    :ok = PubSubNotifier.publish_change(conf, :f)
    # Sync fence: a GenServer.call ensures the notifier has processed the
    # self-broadcast (already in its mailbox) before we assert.
    _ = PubSubNotifier.unique_id(conf)
    assert {:ok, _} = Cache.get(conf, :f)
  end

  test "unique_id/1 returns a stable string id", %{conf: conf} do
    id = PubSubNotifier.unique_id(conf)
    assert is_binary(id)
    assert byte_size(id) == 16
    assert PubSubNotifier.unique_id(conf) == id
  end

  test "the pre-instance arities act on the default instance's notifier", %{conf: conf} do
    assert PubSubNotifier.unique_id() == PubSubNotifier.unique_id(conf)
    Phoenix.PubSub.subscribe(Bandera.Test.PubSub, "bandera:changes")
    assert :ok = PubSubNotifier.publish_change(:legacy)
    assert_receive {:bandera_change, :legacy, _id}
  end

  describe "multiple instances" do
    defp start_instance(name) do
      start_supervised!(
        {Bandera,
         name: name,
         cache_bust_notifications: [
           enabled: true,
           adapter: PubSubNotifier,
           client: Bandera.Test.PubSub
         ]}
      )

      Config.get(name)
    end

    test "the default instance's topic is unchanged", %{conf: conf} do
      assert Notifications.topic(conf) == "bandera:changes"
    end

    test "instances subscribe and publish on their own topic, isolated from each other" do
      a = start_instance(:pubsub_a)
      b = start_instance(:pubsub_b)

      assert Notifications.topic(a) == "bandera:{pubsub_a}:changes"
      assert Notifications.topic(b) == "bandera:{pubsub_b}:changes"

      Cache.put(a, Flag.new(:f, []))
      Cache.put(b, Flag.new(:f, []))

      Phoenix.PubSub.broadcast(
        Bandera.Test.PubSub,
        Notifications.topic(a),
        {:bandera_change, :f, "other-node"}
      )

      wait_until(fn -> match?({:miss, _}, Cache.get(a, :f)) end)
      # Fence: the broadcast is already in b's mailbox if b (wrongly) subscribed to
      # a's topic, so once this call returns b has handled it.
      _ = PubSubNotifier.unique_id(b)
      # b never subscribed to a's topic, so its entry survives.
      assert {:ok, _} = Cache.get(b, :f)
    end

    test "enable/2 broadcasts only on the writing instance's own topic" do
      a = start_instance(:pubsub_a)
      b = start_instance(:pubsub_b)

      # Listen on b's topic only: a write to a must not arrive there...
      Phoenix.PubSub.subscribe(Bandera.Test.PubSub, Notifications.topic(b))
      {:ok, _} = Bandera.enable(:f, instance: :pubsub_a)
      refute_receive {:bandera_change, :f, _id}

      # ...and does arrive on a's own topic.
      Phoenix.PubSub.subscribe(Bandera.Test.PubSub, Notifications.topic(a))
      {:ok, _} = Bandera.disable(:f, instance: :pubsub_a)
      assert_receive {:bandera_change, :f, _id}
      refute_receive {:bandera_change, :f, _id}
    end
  end
end
