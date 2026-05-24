defmodule Bandera.Store.Persistent.Redis.SerializerTest do
  use ExUnit.Case, async: true

  alias Bandera.Flag
  alias Bandera.Gate
  alias Bandera.Store.Persistent.Redis.Serializer

  doctest Bandera.Store.Persistent.Redis.Serializer

  describe "serialize/1 -> {field, value}" do
    test "boolean" do
      assert {"boolean", "true"} = Serializer.serialize(Gate.new(:boolean, true))
      assert {"boolean", "false"} = Serializer.serialize(Gate.new(:boolean, false))
    end

    test "actor / group use the gate id as the field" do
      assert {"actor/42", "true"} = Serializer.serialize(Gate.new(:actor, %{id: 42}, true))
      assert {"group/admin", "false"} = Serializer.serialize(Gate.new(:group, :admin, false))
    end

    test "both percentage types share the 'percentage' field; kind+ratio in the value" do
      assert {"percentage", "time/0.3"} = Serializer.serialize(Gate.new(:percentage_of_time, 0.3))

      assert {"percentage", "actors/0.7"} =
               Serializer.serialize(Gate.new(:percentage_of_actors, 0.7))
    end
  end

  test "field/1 returns the hash field (gate id) for deletes" do
    assert Serializer.field(Gate.new(:boolean, true)) == "boolean"
    assert Serializer.field(Gate.new(:actor, %{id: 9}, true)) == "actor/9"
    assert Serializer.field(Gate.new(:percentage_of_actors, 0.5)) == "percentage"
  end

  describe "deserialize_flag/2 (from a flat HGETALL list)" do
    test "empty -> empty flag" do
      assert %Flag{name: :f, gates: []} = Serializer.deserialize_flag(:f, [])
    end

    test "round-trips each gate type from [field, value] pairs" do
      for gate <- [
            Gate.new(:boolean, true),
            Gate.new(:actor, %{id: 7}, false),
            Gate.new(:group, :beta, true),
            Gate.new(:percentage_of_time, 0.25),
            Gate.new(:percentage_of_actors, 0.5)
          ] do
        {field, value} = Serializer.serialize(gate)
        assert %Flag{name: :f, gates: [^gate]} = Serializer.deserialize_flag(:f, [field, value])
      end
    end

    test "builds a flag from multiple field/value pairs" do
      flat = ["boolean", "true", "actor/1", "false"]
      %Flag{name: :f, gates: gates} = Serializer.deserialize_flag(:f, flat)
      assert length(gates) == 2
      assert Enum.any?(gates, &match?(%Gate{type: :boolean, enabled: true}, &1))
      assert Enum.any?(gates, &match?(%Gate{type: :actor, for: "1", enabled: false}, &1))
    end

    test "accepts a string flag name and returns an atom-named flag" do
      assert %Flag{name: :my_flag, gates: []} = Serializer.deserialize_flag("my_flag", [])
    end
  end

  test "round-trips a segment gate" do
    gate = Gate.new(:segment, :premium_us, true)
    {field, value} = Serializer.serialize(gate)
    assert field == "segment/premium_us"
    assert %Flag{gates: [^gate]} = Serializer.deserialize_flag(:f, [field, value])
  end

  test "round-trips a rule gate via JSON, preserving enabled" do
    gate = Gate.new(:rule, [Bandera.Constraint.new("plan", :eq, "premium")], true)
    {field, value} = Serializer.serialize(gate)
    assert field == "rule"

    assert Jason.decode!(value) == %{
             "enabled" => true,
             "constraints" => [
               %{"attribute" => "plan", "operator" => "eq", "values" => ["premium"]}
             ]
           }

    assert %Flag{gates: [^gate]} = Serializer.deserialize_flag(:f, [field, value])
  end

  test "round-trips a disabled rule gate (enabled is not silently dropped)" do
    gate = Gate.new(:rule, [Bandera.Constraint.new("plan", :eq, "premium")], false)
    {field, value} = Serializer.serialize(gate)
    assert %Flag{gates: [^gate]} = Serializer.deserialize_flag(:f, [field, value])
  end

  test "reads the legacy bare-array rule format as enabled" do
    legacy =
      Jason.encode!([%{"attribute" => "plan", "operator" => "eq", "values" => ["premium"]}])

    assert %Flag{gates: [%Gate{type: :rule, enabled: true, value: [constraint]}]} =
             Serializer.deserialize_flag(:f, ["rule", legacy])

    assert constraint == Bandera.Constraint.new("plan", :eq, "premium")
  end

  test "round-trips a prerequisite gate" do
    gate = Gate.new(:prerequisite, :parent, true)
    {field, value} = Serializer.serialize(gate)
    assert field == "prerequisite/parent"
    assert %Flag{gates: [^gate]} = Serializer.deserialize_flag(:f, [field, value])
  end

  test "round-trips a schedule gate" do
    gate = Gate.new(:schedule, {"2026-01-01T00:00:00Z", nil})
    {field, value} = Serializer.serialize(gate)
    assert field == "schedule"
    assert %Flag{gates: [^gate]} = Serializer.deserialize_flag(:f, [field, value])
  end

  test "round-trips a variant gate via JSON" do
    gate = Bandera.Gate.new(:variant, %{"a" => 1, "b" => 2})
    {field, value} = Serializer.serialize(gate)
    assert field == "variant"
    assert Jason.decode!(value) == %{"a" => 1, "b" => 2}

    assert %Bandera.Flag{gates: [^gate]} = Serializer.deserialize_flag(:f, [field, value])
  end

  describe "fail-soft deserialization" do
    import ExUnit.CaptureLog

    test "a corrupt field is dropped and the rest of the flag survives" do
      {flag, _log} =
        with_log(fn ->
          Serializer.deserialize_flag(:f, ["boolean", "true", "variant", "{not json"])
        end)

      assert %Flag{gates: [%Gate{type: :boolean, enabled: true}]} = flag
    end

    test "an unknown field is dropped, not raised" do
      {flag, _log} =
        with_log(fn ->
          Serializer.deserialize_flag(:f, ["boolean", "true", "from_the_future", "x"])
        end)

      assert %Flag{gates: [%Gate{type: :boolean}]} = flag
    end
  end
end
