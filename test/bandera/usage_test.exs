defmodule Bandera.UsageTest do
  use ExUnit.Case, async: false
  alias Bandera.Usage

  setup do
    start_supervised!(Usage)
    :ok = Usage.attach()
    on_exit(fn -> Usage.detach() end)
    :ok
  end

  test "records the last time a flag was evaluated via [:bandera, :enabled?]" do
    refute Usage.last_evaluated(:never_checked)

    :telemetry.execute([:bandera, :enabled?], %{system_time: 1}, %{
      flag_name: :checked,
      options: [],
      result: false
    })

    assert %DateTime{} = Usage.last_evaluated(:checked)
  end

  test "records variant resolutions via [:bandera, :variant]" do
    refute Usage.last_evaluated(:hero)

    :telemetry.execute([:bandera, :variant], %{system_time: 1}, %{
      flag_name: :hero,
      options: [for: %{id: 1}],
      result: "blue"
    })

    assert %DateTime{} = Usage.last_evaluated(:hero)
  end
end
