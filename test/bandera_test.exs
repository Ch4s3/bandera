defmodule BanderaTest do
  use ExUnit.Case
  doctest Bandera

  test "greets the world" do
    assert Bandera.hello() == :world
  end
end
