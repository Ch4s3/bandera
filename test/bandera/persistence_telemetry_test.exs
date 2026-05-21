defmodule Bandera.PersistenceTelemetryTest do
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
    Bandera.reload_config()

    handler = {__MODULE__, System.unique_integer()}
    test_pid = self()

    :telemetry.attach_many(
      handler,
      [
        [:bandera, :persistence, :get],
        [:bandera, :persistence, :put, :start],
        [:bandera, :persistence, :put, :stop],
        [:bandera, :persistence, :delete, :start],
        [:bandera, :persistence, :delete, :stop],
        [:bandera, :persistence, :all_flags, :stop],
        [:bandera, :persistence, :all_flag_names, :stop]
      ],
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler)
      for k <- [:persistence, :cache], do: Application.delete_env(:bandera, k)
      Bandera.reload_config()
    end)

    :ok
  end

  test "put emits a persistence put span" do
    {:ok, _} = TwoLevel.put(:f, Gate.new(:boolean, true))

    assert_receive {:telemetry, [:bandera, :persistence, :put, :start], _m,
                    %{flag_name: :f, gate: %Gate{}}}

    assert_receive {:telemetry, [:bandera, :persistence, :put, :stop], meas,
                    %{flag_name: :f, gate: %Gate{}}}

    assert is_integer(meas.duration)
  end

  test "get fires on a cache MISS but not on a cache HIT" do
    {:ok, _} = TwoLevel.put(:f, Gate.new(:boolean, true))
    Cache.flush()

    # miss -> reads persistent -> :get event
    {:ok, _} = TwoLevel.lookup(:f)
    assert_receive {:telemetry, [:bandera, :persistence, :get], meas, %{flag_name: :f}}
    assert is_integer(meas.system_time)

    # now cached -> hit -> NO :get event
    {:ok, _} = TwoLevel.lookup(:f)
    refute_receive {:telemetry, [:bandera, :persistence, :get], _m, _meta}
  end

  test "delete, all_flags, all_flag_names emit spans" do
    {:ok, _} = TwoLevel.put(:f, Gate.new(:boolean, true))
    {:ok, _} = TwoLevel.delete(:f)
    assert_receive {:telemetry, [:bandera, :persistence, :delete, :stop], _m, %{flag_name: :f}}

    {:ok, _} = TwoLevel.all_flags()
    assert_receive {:telemetry, [:bandera, :persistence, :all_flags, :stop], _m, _meta}

    {:ok, _} = TwoLevel.all_flag_names()
    assert_receive {:telemetry, [:bandera, :persistence, :all_flag_names, :stop], _m, _meta}
  end

  test "delete/2 emits a delete span carrying the gate" do
    {:ok, _} = TwoLevel.put(:f, Gate.new(:actor, %{id: 1}, true))
    {:ok, _} = TwoLevel.delete(:f, Gate.new(:actor, %{id: 1}, true))

    assert_receive {:telemetry, [:bandera, :persistence, :delete, :start], _m,
                    %{flag_name: :f, gate: %Gate{type: :actor}}}

    assert_receive {:telemetry, [:bandera, :persistence, :delete, :stop], _meas,
                    %{flag_name: :f, gate: %Gate{type: :actor}}}
  end

  test "get fires when the cache is disabled" do
    {:ok, _} = TwoLevel.put(:f, Gate.new(:boolean, true))
    Application.put_env(:bandera, :cache, enabled: false, ttl: 900)
    Bandera.reload_config()

    {:ok, _} = TwoLevel.lookup(:f)
    assert_receive {:telemetry, [:bandera, :persistence, :get], _meas, %{flag_name: :f}}
  end
end
