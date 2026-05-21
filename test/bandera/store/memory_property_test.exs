defmodule Bandera.Store.Persistent.MemoryPropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Bandera.Gate
  alias Bandera.Store.Persistent.Memory

  setup do
    start_supervised!(Memory)
    :ok
  end

  property "put then get round-trips a boolean gate; delete clears it" do
    check all(
            name <- member_of([:f1, :f2, :f3, :f4, :f5]),
            enabled <- boolean(),
            max_runs: 50
          ) do
      {:ok, flag} = Memory.put(name, Gate.new(:boolean, enabled))
      assert {:ok, ^flag} = Memory.get(name)
      assert [%Gate{type: :boolean, enabled: ^enabled}] = flag.gates

      {:ok, empty} = Memory.delete(name)
      assert empty.gates == []
    end
  end
end
