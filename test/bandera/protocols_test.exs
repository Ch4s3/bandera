defmodule Bandera.ProtocolsTest do
  use ExUnit.Case, async: true

  doctest Bandera.Actor
  doctest Bandera.Group

  test "Actor.id/1 for a map uses :id and stringifies it" do
    assert Bandera.Actor.id(%{id: 42}) == "42"
    assert Bandera.Actor.id(%{id: "abc"}) == "abc"
  end

  test "Actor.id/1 for binaries and integers" do
    assert Bandera.Actor.id("user-1") == "user-1"
    assert Bandera.Actor.id(7) == "7"
  end

  test "Group.in?/2 for a map checks membership in :groups (string-compared)" do
    actor = %{id: 1, groups: [:admin, "beta"]}
    assert Bandera.Group.in?(actor, "admin")
    assert Bandera.Group.in?(actor, "beta")
    refute Bandera.Group.in?(actor, "staff")
  end

  test "Group.in?/2 defaults to false for values without group info" do
    refute Bandera.Group.in?("user-1", "admin")
  end

  test "Actor.id/1 raises a clear error for a map without :id" do
    assert_raise ArgumentError, ~r/no :id key/, fn -> Bandera.Actor.id(%{name: "alice"}) end
  end

  test "Group.in?/2 defaults to false for integers" do
    refute Bandera.Group.in?(42, "admin")
  end
end
