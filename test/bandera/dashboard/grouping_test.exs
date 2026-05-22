defmodule Bandera.Dashboard.GroupingTest do
  use ExUnit.Case, async: true

  alias Bandera.Dashboard.Grouping
  alias Bandera.Flag

  defp flag(name), do: Flag.new(name)

  test "splits on the first separator: prefix is group, remainder is display name" do
    flags = [flag(:billing_checkout_v2), flag(:billing_invoices)]

    assert Grouping.group(flags, "_") == [
             {"billing",
              [{"checkout_v2", flag(:billing_checkout_v2)}, {"invoices", flag(:billing_invoices)}]}
           ]
  end

  test "names without the separator land in Ungrouped, which sorts last" do
    flags = [flag(:beta), flag(:billing_checkout)]

    assert Grouping.group(flags, "_") == [
             {"billing", [{"checkout", flag(:billing_checkout)}]},
             {"Ungrouped", [{"beta", flag(:beta)}]}
           ]
  end

  test "groups sort alphabetically and members sort by display name" do
    flags = [flag(:search_fuzzy), flag(:billing_z), flag(:billing_a)]

    assert Grouping.group(flags, "_") == [
             {"billing", [{"a", flag(:billing_a)}, {"z", flag(:billing_z)}]},
             {"search", [{"fuzzy", flag(:search_fuzzy)}]}
           ]
  end

  test "a leading separator (empty prefix) is treated as Ungrouped with the full name" do
    flags = [flag(:_internal)]

    assert Grouping.group(flags, "_") == [{"Ungrouped", [{"_internal", flag(:_internal)}]}]
  end

  test "a nil separator puts everything in Ungrouped with full names" do
    flags = [flag(:billing_checkout), flag(:beta)]

    assert Grouping.group(flags, nil) == [
             {"Ungrouped", [{"beta", flag(:beta)}, {"billing_checkout", flag(:billing_checkout)}]}
           ]
  end

  test "empty input yields an empty list" do
    assert Grouping.group([], "_") == []
  end
end
