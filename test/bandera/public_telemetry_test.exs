defmodule Bandera.PublicTelemetryTest do
  use ExUnit.Case, async: false

  alias Bandera.Store.Cache
  alias Bandera.Store.Persistent.Memory

  setup do
    start_supervised!(Memory)
    start_supervised!(Cache)
    Application.put_env(:bandera, :persistence, adapter: Memory)
    Application.put_env(:bandera, :store, Bandera.Store.TwoLevel)
    Application.put_env(:bandera, :cache, enabled: true, ttl: 900)
    Bandera.reload_config()

    handler = {__MODULE__, System.unique_integer()}
    test_pid = self()

    :telemetry.attach_many(
      handler,
      [
        [:bandera, :enabled?],
        [:bandera, :enable, :start],
        [:bandera, :enable, :stop],
        [:bandera, :disable, :start],
        [:bandera, :disable, :stop],
        [:bandera, :clear, :start],
        [:bandera, :clear, :stop]
      ],
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler)
      for k <- [:persistence, :store, :cache], do: Application.delete_env(:bandera, k)
      Bandera.reload_config()
    end)

    :ok
  end

  test "enabled? emits a point-in-time event with the result" do
    {:ok, _} = Bandera.enable(:f)
    assert Bandera.enabled?(:f) == true

    assert_receive {:telemetry, [:bandera, :enabled?], meas,
                    %{flag_name: :f, options: [], result: true}}

    assert is_integer(meas.system_time)
  end

  test "enable emits a span (start + stop with result)" do
    assert {:ok, true} = Bandera.enable(:f)
    assert_receive {:telemetry, [:bandera, :enable, :start], _m, %{flag_name: :f, options: []}}
    assert_receive {:telemetry, [:bandera, :enable, :stop], meas, meta}
    assert is_integer(meas.duration)
    assert meta.result == {:ok, true}
  end

  test "disable and clear emit span start + stop events" do
    {:ok, _} = Bandera.enable(:f)

    assert {:ok, false} = Bandera.disable(:f)
    assert_receive {:telemetry, [:bandera, :disable, :start], _m, %{flag_name: :f, options: []}}
    assert_receive {:telemetry, [:bandera, :disable, :stop], _meas, %{result: {:ok, false}}}

    assert :ok = Bandera.clear(:f)
    assert_receive {:telemetry, [:bandera, :clear, :start], _m, %{flag_name: :f, options: []}}
    assert_receive {:telemetry, [:bandera, :clear, :stop], _meas, %{result: :ok}}
  end

  test "enabled? for: nil delegates and still emits one event with options []" do
    assert Bandera.enabled?(:none, for: nil) == false

    assert_receive {:telemetry, [:bandera, :enabled?], _m,
                    %{flag_name: :none, options: [], result: false}}
  end

  test "enabled?(flag, for: actor) emits an event carrying options: [for: actor]" do
    {:ok, _} = Bandera.enable(:f, for_actor: %{id: 1})
    assert Bandera.enabled?(:f, for: %{id: 1}) == true

    assert_receive {:telemetry, [:bandera, :enabled?], _m,
                    %{flag_name: :f, options: [for: %{id: 1}], result: true}}
  end
end
