defmodule Bandera.FlagTest do
  use ExUnit.Case, async: true
  alias Bandera.Flag
  alias Bandera.Gate

  doctest Bandera.Flag

  test "empty flag is disabled" do
    refute Flag.enabled?(Flag.new(:x))
  end

  test "boolean gate drives the no-actor result" do
    assert Flag.enabled?(Flag.new(:x, [Gate.new(:boolean, true)]))
    refute Flag.enabled?(Flag.new(:x, [Gate.new(:boolean, false)]))
  end

  test "actor gate overrides boolean" do
    gates = [Gate.new(:boolean, false), Gate.new(:actor, %{id: 1}, true)]
    flag = Flag.new(:x, gates)
    assert Flag.enabled?(flag, for: %{id: 1})
    refute Flag.enabled?(flag, for: %{id: 2})
  end

  test "group gate overrides boolean; enabling group wins over disabling group" do
    gates = [
      Gate.new(:boolean, false),
      Gate.new(:group, :disabled_grp, false),
      Gate.new(:group, :enabled_grp, true)
    ]

    flag = Flag.new(:x, gates)
    assert Flag.enabled?(flag, for: %{id: 1, groups: [:enabled_grp, :disabled_grp]})
    refute Flag.enabled?(flag, for: %{id: 2, groups: [:disabled_grp]})
  end

  test "actor gate overrides group gate" do
    gates = [Gate.new(:group, :admin, true), Gate.new(:actor, %{id: 1}, false)]
    flag = Flag.new(:x, gates)
    refute Flag.enabled?(flag, for: %{id: 1, groups: [:admin]})
  end

  test "percentage_of_actors gate is deterministic per actor" do
    flag = Flag.new(:my_flag, [Gate.new(:percentage_of_actors, 0.5)])
    actor = %{id: 123}
    result = Flag.enabled?(flag, for: actor)
    assert result == Gate.score(actor, :my_flag) <= 0.5
    assert Flag.enabled?(flag, for: actor) == result
  end

  test "group gates fall through to the boolean gate when the actor is in no group" do
    gates = [Gate.new(:boolean, true), Gate.new(:group, :admin, false)]
    flag = Flag.new(:x, gates)
    # actor is not in :admin -> all group gates :ignore -> falls through to boolean (true)
    assert Flag.enabled?(flag, for: %{id: 1, groups: [:staff]})
  end

  test "percentage_of_actors is preferred over percentage_of_time in the actor path" do
    gates = [
      Gate.new(:percentage_of_actors, 0.4),
      Gate.new(:percentage_of_time, 0.999999)
    ]

    flag = Flag.new(:combo, gates)
    actor = %{id: 42}
    expected = Gate.score(actor, :combo) <= 0.4

    # Deterministic across many calls proves the actor-based gate is used,
    # not the (random) percentage_of_time gate.
    results = Enum.map(1..50, fn _ -> Flag.enabled?(flag, for: actor) end)
    assert Enum.uniq(results) == [expected]
  end
end
