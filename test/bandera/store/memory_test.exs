defmodule Bandera.Store.Persistent.MemoryTest do
  use ExUnit.Case, async: false
  alias Bandera.Flag
  alias Bandera.Gate
  alias Bandera.Store.Persistent.Memory

  doctest Bandera.Store.Persistent.Memory

  setup do
    start_supervised!(Memory)
    :ok
  end

  test "put then get returns a flag with the gate" do
    {:ok, flag} = Memory.put(conf(), :f, Gate.new(:boolean, true))
    assert %Flag{name: :f, gates: [%Gate{type: :boolean, enabled: true}]} = flag
    assert {:ok, ^flag} = Memory.get(conf(), :f)
  end

  test "putting the same gate id replaces it" do
    {:ok, _} = Memory.put(conf(), :f, Gate.new(:boolean, true))
    {:ok, flag} = Memory.put(conf(), :f, Gate.new(:boolean, false))
    assert [%Gate{type: :boolean, enabled: false}] = flag.gates
  end

  test "both percentage gate types share one slot" do
    {:ok, _} = Memory.put(conf(), :f, Gate.new(:percentage_of_time, 0.3))
    {:ok, flag} = Memory.put(conf(), :f, Gate.new(:percentage_of_actors, 0.7))
    assert [%Gate{type: :percentage_of_actors, for: 0.7}] = flag.gates
  end

  test "delete/2 removes a single gate; delete/1 removes the whole flag" do
    {:ok, _} = Memory.put(conf(), :f, Gate.new(:boolean, true))
    {:ok, _} = Memory.put(conf(), :f, Gate.new(:actor, %{id: 1}, true))
    {:ok, flag} = Memory.delete(conf(), :f, Gate.new(:actor, %{id: 1}, true))
    assert [%Gate{type: :boolean}] = flag.gates

    {:ok, empty} = Memory.delete(conf(), :f)
    assert empty.gates == []
  end

  test "all_flag_names and all_flags" do
    {:ok, _} = Memory.put(conf(), :a, Gate.new(:boolean, true))
    {:ok, _} = Memory.put(conf(), :b, Gate.new(:boolean, false))
    {:ok, names} = Memory.all_flag_names(conf())
    assert Enum.sort(names) == [:a, :b]
    {:ok, flags} = Memory.all_flags(conf())
    assert length(flags) == 2
  end

  test "the pre-instance arities act on the default instance" do
    {:ok, _} = Memory.put(:legacy, Gate.new(:boolean, true))
    {:ok, _} = Memory.put(:legacy, Gate.new(:actor, %{id: 1}, true))
    assert {:ok, %Flag{gates: [_, _]}} = Memory.get(:legacy)

    assert {:ok, %Flag{gates: [%Gate{type: :boolean}]}} =
             Memory.delete(:legacy, Gate.new(:actor, %{id: 1}, true))

    assert {:ok, [:legacy]} = Memory.all_flag_names()
    assert {:ok, [%Flag{name: :legacy}]} = Memory.all_flags()
    assert {:ok, %Flag{gates: []}} = Memory.delete(:legacy)
    assert {:ok, %Flag{gates: []}} = Memory.get(conf(), :legacy)
  end

  defp conf, do: Bandera.Config.get()
end
