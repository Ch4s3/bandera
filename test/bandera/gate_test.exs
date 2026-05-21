defmodule Bandera.GateTest do
  use ExUnit.Case, async: true
  alias Bandera.Gate

  test "boolean gate evaluates to its value regardless of actor" do
    gate = Gate.new(:boolean, true)
    assert Gate.enabled?(gate) == {:ok, true}
    assert Gate.enabled?(gate, for: %{id: 1}) == {:ok, true}
  end

  test "actor gate matches by actor id, otherwise :ignore" do
    gate = Gate.new(:actor, %{id: 99}, true)
    assert Gate.enabled?(gate, for: %{id: 99}) == {:ok, true}
    assert Gate.enabled?(gate, for: %{id: 1}) == :ignore
    assert Gate.enabled?(gate, []) == :ignore
  end

  test "group gate matches by membership, otherwise :ignore" do
    gate = Gate.new(:group, :admin, true)
    assert Gate.enabled?(gate, for: %{id: 1, groups: [:admin]}) == {:ok, true}
    assert Gate.enabled?(gate, for: %{id: 1, groups: [:staff]}) == :ignore
  end

  test "new/2 rejects out-of-range percentage ratios" do
    assert_raise Gate.InvalidTargetError, fn -> Gate.new(:percentage_of_time, 0.0) end
    assert_raise Gate.InvalidTargetError, fn -> Gate.new(:percentage_of_actors, 1.0) end
  end

  test "score/2 is deterministic in [0,1) and depends on flag name" do
    s1 = Gate.score(%{id: 1}, :flag_a)
    s2 = Gate.score(%{id: 1}, :flag_a)
    s3 = Gate.score(%{id: 1}, :flag_b)
    assert s1 == s2
    assert s1 != s3
    assert s1 >= 0.0 and s1 < 1.0
  end

  test "id/1 collapses both percentage types to a single id" do
    assert Gate.id(Gate.new(:percentage_of_time, 0.5)) == "percentage"
    assert Gate.id(Gate.new(:percentage_of_actors, 0.5)) == "percentage"
    assert Gate.id(Gate.new(:boolean, true)) == "boolean"
    assert Gate.id(Gate.new(:actor, %{id: 9}, true)) == "actor/9"
    assert Gate.id(Gate.new(:group, :admin, true)) == "group/admin"
  end
end
