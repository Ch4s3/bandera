defmodule Bandera.FlagPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Bandera.Flag
  alias Bandera.Gate

  property "a lone boolean gate determines the result for every actor" do
    check all(
            enabled <- boolean(),
            id <- integer(1..1_000_000)
          ) do
      flag = Flag.new(:p, [Gate.new(:boolean, enabled)])
      assert Flag.enabled?(flag) == enabled
      assert Flag.enabled?(flag, for: %{id: id}) == enabled
    end
  end

  property "an actor gate overrides the boolean gate for that actor" do
    check all(
            bool <- boolean(),
            actor_val <- boolean(),
            id <- integer(1..1_000_000)
          ) do
      actor = %{id: id}
      flag = Flag.new(:p, [Gate.new(:boolean, bool), Gate.new(:actor, actor, actor_val)])
      assert Flag.enabled?(flag, for: actor) == actor_val
    end
  end

  property "percentage_of_actors matches the deterministic score comparison" do
    ratio = 0.5

    check all(id <- integer(1..1_000_000)) do
      flag = Flag.new(:pa, [Gate.new(:percentage_of_actors, ratio)])
      actor = %{id: id}
      assert Flag.enabled?(flag, for: actor) == Gate.score(actor, :pa) <= ratio
    end
  end
end
