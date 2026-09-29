defmodule Bandera.Store.ProcessScopedTest do
  use ExUnit.Case, async: true

  alias Bandera.Config
  alias Bandera.Flag
  alias Bandera.Gate
  alias Bandera.Store.ProcessScoped

  setup do
    {:ok,
     conf: Config.new(name: :process_scoped_test),
     other_conf: Config.new(name: :process_scoped_test_other)}
  end

  test "put then lookup round-trips a gate; lookup of an unset flag is empty", %{conf: conf} do
    assert {:ok, %Flag{name: :unset, gates: []}} = ProcessScoped.lookup(conf, :unset)

    {:ok, flag} = ProcessScoped.put(conf, :f, Gate.new(:boolean, true))
    assert %Flag{name: :f, gates: [%Gate{type: :boolean, enabled: true}]} = flag
    assert {:ok, ^flag} = ProcessScoped.lookup(conf, :f)
  end

  test "delete/3 removes one gate; delete/2 removes the whole flag", %{conf: conf} do
    {:ok, _} = ProcessScoped.put(conf, :f, Gate.new(:boolean, true))
    {:ok, _} = ProcessScoped.put(conf, :f, Gate.new(:actor, %{id: 1}, true))

    {:ok, flag} = ProcessScoped.delete(conf, :f, Gate.new(:actor, %{id: 1}, true))
    assert [%Gate{type: :boolean}] = flag.gates

    {:ok, empty} = ProcessScoped.delete(conf, :f)
    assert empty.gates == []
  end

  test "all_flags / all_flag_names reflect this process's overrides", %{conf: conf} do
    {:ok, _} = ProcessScoped.put(conf, :a, Gate.new(:boolean, true))
    {:ok, _} = ProcessScoped.put(conf, :b, Gate.new(:boolean, false))

    {:ok, names} = ProcessScoped.all_flag_names(conf)
    assert Enum.sort(names) == [:a, :b]
    {:ok, flags} = ProcessScoped.all_flags(conf)
    assert length(flags) == 2
  end

  test "overrides are NOT visible to an unrelated process", %{conf: conf} do
    {:ok, _} = ProcessScoped.put(conf, :iso, Gate.new(:boolean, true))
    assert {:ok, %Flag{gates: [_]}} = ProcessScoped.lookup(conf, :iso)

    parent = self()
    spawn(fn -> send(parent, {:result, ProcessScoped.lookup(conf, :iso)}) end)
    assert_receive {:result, {:ok, %Flag{name: :iso, gates: []}}}
  end

  test "overrides ARE visible to descendant processes via $callers", %{conf: conf} do
    {:ok, _} = ProcessScoped.put(conf, :inh, Gate.new(:boolean, true))

    task = Task.async(fn -> ProcessScoped.lookup(conf, :inh) end)

    assert {:ok, %Flag{name: :inh, gates: [%Gate{type: :boolean, enabled: true}]}} =
             Task.await(task)
  end

  test "a non-descendant process granted an allowance sees the override", %{conf: conf} do
    {:ok, _} = ProcessScoped.put(conf, :allowed, Gate.new(:boolean, true))

    parent = self()

    pid =
      spawn(fn ->
        receive do
          :go -> send(parent, {:result, ProcessScoped.lookup(conf, :allowed)})
        end
      end)

    :ok = NimbleOwnership.allow(ProcessScoped, self(), pid, {:flags, conf.name})
    send(pid, :go)
    assert_receive {:result, {:ok, %Flag{name: :allowed, gates: [%Gate{enabled: true}]}}}
  end

  test "the default instance keeps the historical :flags ownership key (allow/4 compatibility)" do
    {:ok, _} = ProcessScoped.put(:allowed_default, Gate.new(:boolean, true))
    parent = self()

    pid =
      spawn(fn ->
        receive do
          :go -> send(parent, {:result, ProcessScoped.lookup(:allowed_default)})
        end
      end)

    :ok = NimbleOwnership.allow(ProcessScoped, self(), pid, :flags)
    send(pid, :go)
    assert_receive {:result, {:ok, %Flag{gates: [%Gate{enabled: true}]}}}
  end

  test "the pre-instance arities act on the default instance" do
    {:ok, _} = ProcessScoped.put(:legacy, Gate.new(:boolean, true))
    {:ok, _} = ProcessScoped.put(:legacy, Gate.new(:actor, %{id: 1}, true))
    assert {:ok, %Flag{gates: [_, _]}} = ProcessScoped.lookup(:legacy)
    assert {:ok, %Flag{gates: [_, _]}} = ProcessScoped.lookup(Config.new(), :legacy)

    assert {:ok, %Flag{gates: [%Gate{type: :boolean}]}} =
             ProcessScoped.delete(:legacy, Gate.new(:actor, %{id: 1}, true))

    assert {:ok, [:legacy]} = ProcessScoped.all_flag_names()
    assert {:ok, [%Flag{name: :legacy}]} = ProcessScoped.all_flags()
    assert {:ok, %Flag{gates: []}} = ProcessScoped.delete(:legacy)
  end

  test "both percentage gate types share one slot (parity with Memory)", %{conf: conf} do
    {:ok, _} = ProcessScoped.put(conf, :pct, Gate.new(:percentage_of_time, 0.3))
    {:ok, flag} = ProcessScoped.put(conf, :pct, Gate.new(:percentage_of_actors, 0.7))
    assert [%Gate{type: :percentage_of_actors, for: 0.7}] = flag.gates
  end

  test "variant gate round-trips through ProcessScoped (adapter parity)", %{conf: conf} do
    gate = Gate.new(:variant, %{"blue" => 1, "green" => 1})
    {:ok, flag} = ProcessScoped.put(conf, :exp, gate)
    assert %Flag{name: :exp, gates: [^gate]} = flag
    assert {:ok, ^flag} = ProcessScoped.lookup(conf, :exp)
  end

  test "overrides are scoped per instance: setting a flag under one config is invisible to another",
       %{conf: conf, other_conf: other_conf} do
    {:ok, _} = ProcessScoped.put(conf, :shared_name, Gate.new(:boolean, true))

    assert {:ok, %Flag{gates: [_]}} = ProcessScoped.lookup(conf, :shared_name)
    assert {:ok, %Flag{gates: []}} = ProcessScoped.lookup(other_conf, :shared_name)
  end
end
