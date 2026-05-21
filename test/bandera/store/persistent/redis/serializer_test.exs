defmodule Bandera.Store.Persistent.Redis.SerializerTest do
  use ExUnit.Case, async: true

  alias Bandera.Flag
  alias Bandera.Gate
  alias Bandera.Store.Persistent.Redis.Serializer

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
end
