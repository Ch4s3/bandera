defmodule Bandera.PercentageDistributionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Bandera.Gate

  property "actor scores are uniform-ish and stable per actor+flag" do
    check all(id <- integer(1..1_000_000)) do
      score = Gate.score(%{id: id}, :some_flag)
      assert score >= 0.0 and score < 1.0
      assert score == Gate.score(%{id: id}, :some_flag)
    end
  end

  test "score distribution over 10k actors is roughly the target ratio" do
    ratio = 0.30
    n = 10_000
    enabled = Enum.count(1..n, fn id -> Gate.score(%{id: id}, :dist_flag) <= ratio end)
    observed = enabled / n
    assert_in_delta observed, ratio, 0.03
  end
end
