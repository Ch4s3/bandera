defmodule Bandera.Store.Persistent.Ecto.SerializerTest do
  use ExUnit.Case, async: true

  alias Bandera.Flag
  alias Bandera.Gate
  alias Bandera.Store.Persistent.Ecto.Serializer

  describe "to_row/2" do
    test "boolean gate uses the nil-target sentinel" do
      assert %{flag_name: "f", gate_type: "boolean", target: "_bandera_none", enabled: true} =
               Serializer.to_row(:f, Gate.new(:boolean, true))
    end

    test "actor gate stores the actor id as target" do
      assert %{gate_type: "actor", target: "42", enabled: true} =
               Serializer.to_row(:f, Gate.new(:actor, %{id: 42}, true))
    end

    test "group gate stores the group name as target" do
      assert %{gate_type: "group", target: "admin", enabled: false} =
               Serializer.to_row(:f, Gate.new(:group, :admin, false))
    end

    test "percentage gates collapse to gate_type 'percentage' with encoded target" do
      assert %{gate_type: "percentage", target: "time/0.3", enabled: true} =
               Serializer.to_row(:f, Gate.new(:percentage_of_time, 0.3))

      assert %{gate_type: "percentage", target: "actors/0.7", enabled: true} =
               Serializer.to_row(:f, Gate.new(:percentage_of_actors, 0.7))
    end
  end

  describe "deserialize_flag/2 (round-trip)" do
    test "empty rows -> empty flag" do
      assert %Flag{name: :f, gates: []} = Serializer.deserialize_flag(:f, [])
    end

    test "round-trips each gate type" do
      for gate <- [
            Gate.new(:boolean, true),
            Gate.new(:actor, %{id: 7}, false),
            Gate.new(:group, :beta, true),
            Gate.new(:percentage_of_time, 0.25),
            Gate.new(:percentage_of_actors, 0.5)
          ] do
        row = Serializer.to_row(:f, gate)
        assert %Flag{name: :f, gates: [^gate]} = Serializer.deserialize_flag(:f, [row])
      end
    end

    test "builds a flag from multiple rows" do
      rows = [
        Serializer.to_row(:f, Gate.new(:boolean, true)),
        Serializer.to_row(:f, Gate.new(:actor, %{id: 1}, false))
      ]

      %Flag{name: :f, gates: gates} = Serializer.deserialize_flag(:f, rows)
      assert length(gates) == 2
      assert Enum.any?(gates, &match?(%Gate{type: :boolean}, &1))
      assert Enum.any?(gates, &match?(%Gate{type: :actor, for: "1"}, &1))
    end
  end

  test "serialize_target/1 maps nil to the sentinel" do
    assert Serializer.serialize_target(nil) == "_bandera_none"
    assert Serializer.serialize_target("x") == "x"
    assert Serializer.serialize_target(:y) == "y"
  end
end
