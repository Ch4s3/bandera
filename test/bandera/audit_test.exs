defmodule Bandera.AuditTest do
  use ExUnit.Case, async: false

  alias Bandera.Audit
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

  test "from_telemetry/2 builds an Event from an enable :stop event" do
    metadata = %{flag_name: :promo, options: [for_actor: %{id: 7}], result: {:ok, true}}
    event = Audit.from_telemetry([:bandera, :enable, :stop], metadata)

    assert %Audit.Event{
             action: :enable,
             flag_name: :promo,
             options: [for_actor: %{id: 7}],
             result: {:ok, true}
           } = event

    assert %DateTime{} = event.at
  end

  test "attach/2 delivers an Event on every write, detach/1 stops it" do
    test_pid = self()
    :ok = Audit.attach(:audit_test, fn event -> send(test_pid, {:audited, event}) end)
    on_exit(fn -> Audit.detach(:audit_test) end)

    {:ok, _} = Bandera.enable(:promo, by: "admin@example.com")

    assert_receive {:audited,
                    %Audit.Event{action: :enable, flag_name: :promo, actor: "admin@example.com"}}

    {:ok, _} = Bandera.disable(:promo)
    assert_receive {:audited, %Audit.Event{action: :disable, flag_name: :promo}}

    :ok = Audit.detach(:audit_test)
    {:ok, _} = Bandera.enable(:other)
    refute_receive {:audited, _}
  end
end
