defmodule Bandera.TelemetryTest do
  use ExUnit.Case, async: true

  alias Bandera.Telemetry

  defp attach(events) do
    handler = {__MODULE__, System.unique_integer()}
    test_pid = self()

    :telemetry.attach_many(
      handler,
      events,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  test "event/2 emits a point-in-time event with a system_time measurement under the :bandera prefix" do
    attach([[:bandera, :thing]])
    assert Telemetry.event([:thing], %{foo: 1}) == :ok

    assert_receive {:telemetry, [:bandera, :thing], measurements, %{foo: 1}}
    assert is_integer(measurements.system_time)
  end

  test "span/3 emits :start and :stop (with duration), merges start metadata into stop, and returns the result" do
    attach([[:bandera, :op, :start], [:bandera, :op, :stop]])

    result =
      Telemetry.span([:op], %{flag_name: :f}, fn ->
        {:my_result, %{result: :my_result}}
      end)

    assert result == :my_result
    assert_receive {:telemetry, [:bandera, :op, :start], start_meas, %{flag_name: :f}}
    assert is_integer(start_meas.system_time)
    assert_receive {:telemetry, [:bandera, :op, :stop], stop_meas, meta}
    assert is_integer(stop_meas.duration)
    assert meta.flag_name == :f
    assert meta.result == :my_result
  end

  test "span/3 emits :exception when the function raises, carrying start metadata" do
    attach([[:bandera, :op, :exception]])

    assert_raise RuntimeError, fn ->
      Telemetry.span([:op], %{flag_name: :f}, fn -> raise "boom" end)
    end

    assert_receive {:telemetry, [:bandera, :op, :exception], meas, meta}
    assert is_integer(meas.duration)
    assert meta.kind == :error
    assert %RuntimeError{} = meta.reason
    assert meta.flag_name == :f
  end
end
