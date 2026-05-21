defmodule Bandera.NotificationsTest do
  use ExUnit.Case, async: false

  alias Bandera.Gate
  alias Bandera.Store.Cache
  alias Bandera.Store.Persistent.Memory
  alias Bandera.Store.TwoLevel

  setup do
    start_supervised!(Memory)
    start_supervised!(Cache)
    Application.put_env(:bandera, :persistence, adapter: Memory)
    Application.put_env(:bandera, :cache, enabled: true, ttl: 900)

    Application.put_env(:bandera, :cache_bust_notifications,
      enabled: true,
      adapter: Bandera.TestNotifier
    )

    Application.put_env(:bandera, :test_notifier_pid, self())
    Bandera.reload_config()

    on_exit(fn ->
      for k <- [:persistence, :cache, :cache_bust_notifications, :test_notifier_pid] do
        Application.delete_env(:bandera, k)
      end

      Bandera.reload_config()
    end)

    :ok
  end

  test "publish_change/1 is a no-op when notifications are disabled" do
    Application.put_env(:bandera, :cache_bust_notifications,
      enabled: false,
      adapter: Bandera.TestNotifier
    )

    Bandera.reload_config()
    assert Bandera.Notifications.publish_change(:x) == :ok
    refute_received {:published, :x}
  end

  test "TwoLevel.put publishes a change" do
    {:ok, _} = TwoLevel.put(:f, Gate.new(:boolean, true))
    assert_received {:published, :f}
  end

  test "TwoLevel.delete/2 and delete/1 publish a change" do
    {:ok, _} = TwoLevel.put(:f, Gate.new(:boolean, true))
    assert_received {:published, :f}
    {:ok, _} = TwoLevel.delete(:f, Gate.new(:boolean, true))
    assert_received {:published, :f}
    {:ok, _} = TwoLevel.delete(:f)
    assert_received {:published, :f}
  end
end
