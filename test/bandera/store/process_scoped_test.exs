defmodule Bandera.Store.ProcessScopedTest do
  use ExUnit.Case, async: true

  alias Bandera.Flag
  alias Bandera.Gate
  alias Bandera.Store.ProcessScoped

  test "put then lookup round-trips a gate; lookup of an unset flag is empty" do
    assert {:ok, %Flag{name: :unset, gates: []}} = ProcessScoped.lookup(:unset)

    {:ok, flag} = ProcessScoped.put(:f, Gate.new(:boolean, true))
    assert %Flag{name: :f, gates: [%Gate{type: :boolean, enabled: true}]} = flag
    assert {:ok, ^flag} = ProcessScoped.lookup(:f)
  end

  test "delete/2 removes one gate; delete/1 removes the whole flag" do
    {:ok, _} = ProcessScoped.put(:f, Gate.new(:boolean, true))
    {:ok, _} = ProcessScoped.put(:f, Gate.new(:actor, %{id: 1}, true))

    {:ok, flag} = ProcessScoped.delete(:f, Gate.new(:actor, %{id: 1}, true))
    assert [%Gate{type: :boolean}] = flag.gates

    {:ok, empty} = ProcessScoped.delete(:f)
    assert empty.gates == []
  end

  test "all_flags / all_flag_names reflect this process's overrides" do
    {:ok, _} = ProcessScoped.put(:a, Gate.new(:boolean, true))
    {:ok, _} = ProcessScoped.put(:b, Gate.new(:boolean, false))

    {:ok, names} = ProcessScoped.all_flag_names()
    assert Enum.sort(names) == [:a, :b]
    {:ok, flags} = ProcessScoped.all_flags()
    assert length(flags) == 2
  end

  test "overrides are NOT visible to an unrelated process" do
    {:ok, _} = ProcessScoped.put(:iso, Gate.new(:boolean, true))
    assert {:ok, %Flag{gates: [_]}} = ProcessScoped.lookup(:iso)

    parent = self()
    spawn(fn -> send(parent, {:result, ProcessScoped.lookup(:iso)}) end)
    assert_receive {:result, {:ok, %Flag{name: :iso, gates: []}}}
  end

  test "overrides ARE visible to descendant processes via $callers" do
    {:ok, _} = ProcessScoped.put(:inh, Gate.new(:boolean, true))

    task = Task.async(fn -> ProcessScoped.lookup(:inh) end)

    assert {:ok, %Flag{name: :inh, gates: [%Gate{type: :boolean, enabled: true}]}} =
             Task.await(task)
  end

  test "a non-descendant process granted an allowance sees the override" do
    {:ok, _} = ProcessScoped.put(:allowed, Gate.new(:boolean, true))

    parent = self()

    pid =
      spawn(fn ->
        receive do
          :go -> send(parent, {:result, ProcessScoped.lookup(:allowed)})
        end
      end)

    :ok = NimbleOwnership.allow(ProcessScoped, self(), pid, :flags)
    send(pid, :go)
    assert_receive {:result, {:ok, %Flag{name: :allowed, gates: [%Gate{enabled: true}]}}}
  end

  test "both percentage gate types share one slot (parity with Memory)" do
    {:ok, _} = ProcessScoped.put(:pct, Gate.new(:percentage_of_time, 0.3))
    {:ok, flag} = ProcessScoped.put(:pct, Gate.new(:percentage_of_actors, 0.7))
    assert [%Gate{type: :percentage_of_actors, for: 0.7}] = flag.gates
  end
end
