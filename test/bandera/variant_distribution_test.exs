defmodule Bandera.VariantDistributionTest do
  use ExUnit.Case, async: true

  alias Bandera.Flag
  alias Bandera.Gate

  # Allocation is deterministic per actor id (SHA-256 score), so this distribution
  # is stable run-to-run — not a flaky statistical test.

  test "a weighted split is honored in aggregate across many actors" do
    flag = Flag.new(:dist, [Gate.new(:variant, %{"a" => 7, "b" => 3})])
    n = 10_000

    counts =
      Enum.reduce(1..n, %{"a" => 0, "b" => 0}, fn id, acc ->
        Map.update!(acc, Flag.variant(flag, for: %{id: id}), &(&1 + 1))
      end)

    assert_in_delta counts["a"] / n, 0.70, 0.03
    assert_in_delta counts["b"] / n, 0.30, 0.03
  end

  test "every actor lands in one of the declared variants and stays there" do
    flag = Flag.new(:dist, [Gate.new(:variant, %{"x" => 1, "y" => 1, "z" => 1})])

    for id <- 1..500 do
      chosen = Flag.variant(flag, for: %{id: id})
      assert chosen in ["x", "y", "z"]
      assert Flag.variant(flag, for: %{id: id}) == chosen
    end
  end

  test "a zero-weight variant is never chosen" do
    flag = Flag.new(:dist, [Gate.new(:variant, %{"live" => 1, "dead" => 0})])
    chosen = Enum.map(1..500, fn id -> Flag.variant(flag, for: %{id: id}) end)
    assert Enum.uniq(chosen) == ["live"]
  end
end
