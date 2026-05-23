defmodule Bandera.GateTest do
  use ExUnit.Case, async: true
  alias Bandera.Gate

  doctest Bandera.Gate

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

  test "actor gate still matches when extra opts (e.g. flag_name) are present" do
    gate = Gate.new(:actor, %{id: 99}, true)
    assert Gate.enabled?(gate, for: %{id: 99}, flag_name: :f) == {:ok, true}
  end

  test "percentage_of_actors gate uses score to decide eligibility" do
    gate = Gate.new(:percentage_of_actors, 0.5)
    actor = %{id: 7}
    expected = Gate.score(actor, :some_flag) <= 0.5
    assert Gate.enabled?(gate, for: actor, flag_name: :some_flag) == {:ok, expected}
  end

  test "percentage_of_time gate returns an {:ok, boolean}" do
    gate = Gate.new(:percentage_of_time, 0.5)
    assert {:ok, value} = Gate.enabled?(gate)
    assert is_boolean(value)
  end

  test "rule gate holds constraints in :value" do
    constraints = [Bandera.Constraint.new("plan", :eq, "premium")]
    gate = Bandera.Gate.new(:rule, constraints, true)
    assert %Bandera.Gate{type: :rule, for: nil, enabled: true, value: ^constraints} = gate
    assert Bandera.Gate.rule?(gate)
    assert Bandera.Gate.id(gate) == "rule"
  end

  test "prerequisite gate references another flag + required state" do
    gate = Bandera.Gate.new(:prerequisite, :parent, true)
    assert %Bandera.Gate{type: :prerequisite, for: :parent, enabled: true} = gate
    assert Bandera.Gate.prerequisite?(gate)
    assert Bandera.Gate.id(gate) == "prerequisite/parent"
  end

  describe "schedule gates" do
    test "active inside the window, inactive outside" do
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

      open = Bandera.Gate.new(:schedule, {past, future})
      assert {:ok, true} = Bandera.Gate.enabled?(open)

      not_yet = Bandera.Gate.new(:schedule, {future, nil})
      assert {:ok, false} = Bandera.Gate.enabled?(not_yet)
    end

    test "a malformed window bound fails closed instead of crashing" do
      gate = %Bandera.Gate{
        type: :schedule,
        for: nil,
        enabled: true,
        value: %{"from" => "not-a-date", "until" => nil}
      }

      assert {:ok, false} = Bandera.Gate.enabled?(gate)
    end

    test "an open-ended window (both bounds nil) is always active" do
      gate = Bandera.Gate.new(:schedule, {nil, nil})
      assert {:ok, true} = Bandera.Gate.enabled?(gate)
    end

    test "a from-only window is active once started" do
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
      assert {:ok, true} = Bandera.Gate.enabled?(Bandera.Gate.new(:schedule, {past, nil}))
    end

    test "an until-only window is active before it closes and inactive after" do
      future = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_iso8601()
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()

      assert {:ok, true} = Bandera.Gate.enabled?(Bandera.Gate.new(:schedule, {nil, future}))
      assert {:ok, false} = Bandera.Gate.enabled?(Bandera.Gate.new(:schedule, {nil, past}))
    end
  end

  describe "variant gates" do
    test "new/2 builds a variant gate holding the weights map in :value" do
      gate = Bandera.Gate.new(:variant, %{"blue" => 1, "green" => 1})

      assert %Bandera.Gate{
               type: :variant,
               for: nil,
               enabled: true,
               value: %{"blue" => 1, "green" => 1}
             } = gate
    end

    test "variant?/1 and id/1" do
      gate = Bandera.Gate.new(:variant, %{"a" => 1})
      assert Bandera.Gate.variant?(gate)
      refute Bandera.Gate.variant?(Bandera.Gate.new(:boolean, true))
      assert Bandera.Gate.id(gate) == "variant"
    end

    test "new/2 rejects an empty weights map" do
      assert_raise Bandera.Gate.InvalidTargetError, fn -> Bandera.Gate.new(:variant, %{}) end
    end

    test "new/2 rejects an all-zero weights map" do
      assert_raise Bandera.Gate.InvalidTargetError, fn ->
        Bandera.Gate.new(:variant, %{"a" => 0, "b" => 0})
      end
    end

    test "new/2 rejects negative weights" do
      assert_raise Bandera.Gate.InvalidTargetError, fn ->
        Bandera.Gate.new(:variant, %{"a" => -1, "b" => 2})
      end
    end

    test "new/2 rejects non-numeric weights" do
      assert_raise Bandera.Gate.InvalidTargetError, fn ->
        Bandera.Gate.new(:variant, %{"a" => "lots", "b" => 1})
      end
    end
  end
end
