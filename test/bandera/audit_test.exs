defmodule Bandera.AuditTest do
  use ExUnit.Case, async: true

  alias Bandera.Audit

  test "from_telemetry/3 builds an Event from an enable :stop event" do
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
end
