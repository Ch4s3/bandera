defmodule Bandera.Store.Persistent.EctoTest do
  use ExUnit.Case, async: false

  alias Bandera.Config
  alias Bandera.Flag
  alias Bandera.Gate
  alias Bandera.Store.Persistent.Ecto, as: EctoStore

  setup do
    Bandera.TestRepo.query!("DELETE FROM bandera_flags")
    Application.put_env(:bandera, :persistence, adapter: EctoStore, repo: Bandera.TestRepo)
    Bandera.reload_config()

    on_exit(fn ->
      Application.delete_env(:bandera, :persistence)
      Bandera.reload_config()
    end)

    %{conf: Config.get()}
  end

  test "put then get round-trips a boolean gate", %{conf: conf} do
    {:ok, flag} = EctoStore.put(conf, :f, Gate.new(:boolean, true))
    assert %Flag{name: :f, gates: [%Gate{type: :boolean, enabled: true}]} = flag
    assert {:ok, ^flag} = EctoStore.get(conf, :f)
  end

  test "get of an unknown flag returns an empty flag", %{conf: conf} do
    assert {:ok, %Flag{name: :nope, gates: []}} = EctoStore.get(conf, :nope)
  end

  test "putting the same gate id updates enabled (upsert)", %{conf: conf} do
    {:ok, _} = EctoStore.put(conf, :f, Gate.new(:boolean, true))
    {:ok, flag} = EctoStore.put(conf, :f, Gate.new(:boolean, false))
    assert [%Gate{type: :boolean, enabled: false}] = flag.gates
  end

  test "boolean put over an existing sentinel row upserts instead of violating the unique index",
       %{conf: conf} do
    # Regression for the FunWithFlags->Bandera migration incident (23505 on
    # fwf_flag_name_gate_target_idx). The boolean path used to delete_all + bare
    # insert_all with no on_conflict, so under concurrent toggles two writers could
    # both delete then both insert, and the loser's insert hit the
    # (flag_name, gate_type, target) unique index. Insert the sentinel row directly
    # to model "a row is already present when this writer inserts", then assert the
    # put replaces it rather than raising.
    Bandera.TestRepo.query!(
      "INSERT INTO bandera_flags (flag_name, gate_type, target, enabled) VALUES ('race_flag', 'boolean', '_bandera_none', 0)"
    )

    assert {:ok, %Flag{gates: [%Gate{type: :boolean, enabled: true}]}} =
             EctoStore.put(conf, :race_flag, Gate.new(:boolean, true))

    # Exactly one boolean row remains, at the sentinel target (SQLite returns the
    # boolean as an integer over the raw driver).
    %{rows: rows} =
      Bandera.TestRepo.query!(
        "SELECT target, enabled FROM bandera_flags WHERE flag_name = 'race_flag' AND gate_type = 'boolean'"
      )

    assert rows == [["_bandera_none", 1]]
  end

  test "boolean put clears legacy FunWithFlags rows stored at a non-sentinel target", %{
    conf: conf
  } do
    # FunWithFlags stored boolean gates at target = "boolean". A Bandera write must
    # remove that stale row so the flag does not keep two contradictory boolean rows.
    Bandera.TestRepo.query!(
      "INSERT INTO bandera_flags (flag_name, gate_type, target, enabled) VALUES ('legacy_flag', 'boolean', 'boolean', 1)"
    )

    assert {:ok, %Flag{gates: [%Gate{type: :boolean, enabled: false}]}} =
             EctoStore.put(conf, :legacy_flag, Gate.new(:boolean, false))

    %{rows: rows} =
      Bandera.TestRepo.query!(
        "SELECT target, enabled FROM bandera_flags WHERE flag_name = 'legacy_flag' AND gate_type = 'boolean'"
      )

    assert rows == [["_bandera_none", 0]]
  end

  test "actor and group gates coexist and round-trip", %{conf: conf} do
    {:ok, _} = EctoStore.put(conf, :f, Gate.new(:actor, %{id: 1}, true))
    {:ok, _} = EctoStore.put(conf, :f, Gate.new(:group, :admin, false))
    {:ok, %Flag{gates: gates}} = EctoStore.get(conf, :f)
    assert Enum.any?(gates, &match?(%Gate{type: :actor, for: "1", enabled: true}, &1))
    assert Enum.any?(gates, &match?(%Gate{type: :group, for: "admin", enabled: false}, &1))
  end

  test "both percentage types share one slot; switching kind replaces it", %{conf: conf} do
    {:ok, _} = EctoStore.put(conf, :f, Gate.new(:percentage_of_time, 0.3))
    {:ok, flag} = EctoStore.put(conf, :f, Gate.new(:percentage_of_actors, 0.7))
    assert [%Gate{type: :percentage_of_actors, for: 0.7}] = flag.gates
  end

  test "delete/3 removes one gate; delete/2 removes the whole flag", %{conf: conf} do
    {:ok, _} = EctoStore.put(conf, :f, Gate.new(:boolean, true))
    {:ok, _} = EctoStore.put(conf, :f, Gate.new(:actor, %{id: 1}, true))

    {:ok, flag} = EctoStore.delete(conf, :f, Gate.new(:actor, %{id: 1}, true))
    assert [%Gate{type: :boolean}] = flag.gates

    {:ok, empty} = EctoStore.delete(conf, :f)
    assert empty.gates == []
  end

  test "delete/3 with a percentage gate clears the percentage slot", %{conf: conf} do
    {:ok, _} = EctoStore.put(conf, :f, Gate.new(:percentage_of_actors, 0.5))
    # deleting with EITHER percentage type clears the single percentage slot
    {:ok, flag} = EctoStore.delete(conf, :f, Gate.new(:percentage_of_time, 0.5))
    assert flag.gates == []
  end

  test "all_flags and all_flag_names", %{conf: conf} do
    {:ok, _} = EctoStore.put(conf, :a, Gate.new(:boolean, true))
    {:ok, _} = EctoStore.put(conf, :b, Gate.new(:boolean, false))

    {:ok, names} = EctoStore.all_flag_names(conf)
    assert Enum.sort(names) == [:a, :b]
    {:ok, flags} = EctoStore.all_flags(conf)
    assert length(flags) == 2
  end

  test "variant gate persists and resolves through the Ecto adapter", %{conf: conf} do
    {:ok, _flag} = EctoStore.put(conf, :hero, Bandera.Gate.new(:variant, %{"a" => 1, "b" => 1}))
    {:ok, flag} = EctoStore.get(conf, :hero)

    assert [%Bandera.Gate{type: :variant, value: %{"a" => 1, "b" => 1}}] = flag.gates
    v = Bandera.Flag.variant(flag, for: %{id: 7})
    assert v in ["a", "b"]
  end

  test "rule gate round-trips through the value column and evaluates with context", %{
    conf: conf
  } do
    gate = Gate.new(:rule, [Bandera.Constraint.new("plan", :eq, "premium")], true)
    {:ok, _} = EctoStore.put(conf, :billing, gate)
    {:ok, flag} = EctoStore.get(conf, :billing)

    assert [%Gate{type: :rule}] = flag.gates
    assert Flag.enabled?(flag, context: %{"plan" => "premium"})
    refute Flag.enabled?(flag, context: %{"plan" => "free"})
  end

  test "schedule gate round-trips through the value column and gates by window", %{conf: conf} do
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
    future = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_iso8601()

    {:ok, _} = EctoStore.put(conf, :launch, Gate.new(:schedule, {past, future}))
    {:ok, flag} = EctoStore.get(conf, :launch)

    assert [%Gate{type: :schedule, value: %{"from" => ^past, "until" => ^future}}] = flag.gates
    assert Flag.enabled?(flag)
  end

  test "works end-to-end through the public Bandera API via TwoLevel" do
    start_supervised!(Bandera.Store.Cache)
    Application.put_env(:bandera, :store, Bandera.Store.TwoLevel)
    Application.put_env(:bandera, :cache, enabled: true, ttl: 900)
    Bandera.reload_config()

    on_exit(fn ->
      Application.delete_env(:bandera, :store)
      Application.delete_env(:bandera, :cache)
      Bandera.reload_config()
    end)

    refute Bandera.enabled?(:api_flag)
    assert {:ok, true} = Bandera.enable(:api_flag)
    assert Bandera.enabled?(:api_flag)
  end

  describe "storage_id/1" do
    test "identifies the database, prefix, and table this conf points at", %{conf: conf} do
      assert EctoStore.storage_id(conf) == {EctoStore, db(), nil, "bandera_flags"}
    end

    test "identifies the physical database, not the repo module" do
      assert {"", "", database} = db()
      assert database == Bandera.TestRepo.config()[:database]
      # A different repo module configured against the same database file.
      assert EctoStore.database_location(Bandera.TestRepoAlias) == db()
    end

    test "falls back to the repo module when it has no readable database config" do
      assert EctoStore.database_location(Bandera.RecordingRepo) == Bandera.RecordingRepo
    end

    test "differs by table name" do
      other =
        Config.new(
          persistence: [
            adapter: EctoStore,
            repo: Bandera.TestRepo,
            ecto_table_name: "bandera_flags_2"
          ]
        )

      assert EctoStore.storage_id(other) == {EctoStore, db(), nil, "bandera_flags_2"}
    end

    test "differs by prefix" do
      other =
        Config.new(persistence: [adapter: EctoStore, repo: Bandera.TestRepo, prefix: "tenant_a"])

      assert EctoStore.storage_id(other) ==
               {EctoStore, db(), "tenant_a", "bandera_flags"}
    end
  end

  describe "isolation between two instances on the same repo" do
    setup do
      Bandera.TestRepo.query!("DELETE FROM bandera_flags_2")
      on_exit(fn -> Bandera.TestRepo.query!("DELETE FROM bandera_flags_2") end)

      conf_a =
        Config.new(name: :ecto_inst_a, persistence: [adapter: EctoStore, repo: Bandera.TestRepo])

      conf_b =
        Config.new(
          name: :ecto_inst_b,
          persistence: [
            adapter: EctoStore,
            repo: Bandera.TestRepo,
            ecto_table_name: "bandera_flags_2"
          ]
        )

      %{conf_a: conf_a, conf_b: conf_b}
    end

    test "flags written under one instance's table are invisible to the other", %{
      conf_a: conf_a,
      conf_b: conf_b
    } do
      {:ok, _} = EctoStore.put(conf_a, :only_a, Gate.new(:boolean, true))
      {:ok, _} = EctoStore.put(conf_b, :only_b, Gate.new(:boolean, true))

      assert {:ok, [:only_a]} = EctoStore.all_flag_names(conf_a)
      assert {:ok, [:only_b]} = EctoStore.all_flag_names(conf_b)
    end
  end

  describe "prefix propagation" do
    setup do
      test_pid = self()
      Application.put_env(:bandera, :recording_repo_pid, test_pid)
      on_exit(fn -> Application.delete_env(:bandera, :recording_repo_pid) end)
      :ok
    end

    defp drain_calls do
      case Process.info(self(), :messages) do
        {:messages, _} ->
          receive do
            {:repo_call, fun, opts} -> [{fun, opts} | drain_calls()]
          after
            0 -> []
          end
      end
    end

    test "every repo call the boolean put makes carries the configured prefix" do
      conf =
        Config.new(
          persistence: [adapter: EctoStore, repo: Bandera.RecordingRepo, prefix: "tenant_a"]
        )

      EctoStore.put(conf, :f, Gate.new(:boolean, true))

      calls = drain_calls()
      assert calls != []
      assert Enum.all?(calls, fn {_fun, opts} -> Keyword.get(opts, :prefix) == "tenant_a" end)
    end

    test "every repo call the percentage put (transaction path) makes carries the prefix" do
      conf =
        Config.new(
          persistence: [adapter: EctoStore, repo: Bandera.RecordingRepo, prefix: "tenant_a"]
        )

      EctoStore.put(conf, :f, Gate.new(:percentage_of_actors, 0.5))

      calls = drain_calls()
      assert calls != []
      assert Enum.all?(calls, fn {_fun, opts} -> Keyword.get(opts, :prefix) == "tenant_a" end)
    end

    test "get, delete/2, delete/3, all_flags, and all_flag_names all carry the prefix" do
      conf =
        Config.new(
          persistence: [adapter: EctoStore, repo: Bandera.RecordingRepo, prefix: "tenant_a"]
        )

      EctoStore.get(conf, :f)
      EctoStore.delete(conf, :f, Gate.new(:boolean, true))
      EctoStore.delete(conf, :f)
      EctoStore.all_flags(conf)
      EctoStore.all_flag_names(conf)

      calls = drain_calls()
      assert length(calls) >= 5
      assert Enum.all?(calls, fn {_fun, opts} -> Keyword.get(opts, :prefix) == "tenant_a" end)
    end

    test "with no prefix configured, no repo call carries a :prefix option" do
      conf = Config.new(persistence: [adapter: EctoStore, repo: Bandera.RecordingRepo])

      EctoStore.put(conf, :f, Gate.new(:boolean, true))
      EctoStore.put(conf, :f, Gate.new(:percentage_of_actors, 0.5))
      EctoStore.get(conf, :f)
      EctoStore.delete(conf, :f, Gate.new(:boolean, true))
      EctoStore.delete(conf, :f)
      EctoStore.all_flags(conf)
      EctoStore.all_flag_names(conf)

      calls = drain_calls()
      assert calls != []
      assert Enum.all?(calls, fn {_fun, opts} -> not Keyword.has_key?(opts, :prefix) end)
    end
  end

  describe "storage conflict" do
    test "a second instance claiming the same repo+prefix+table refuses to start" do
      opts = [
        persistence: [
          adapter: EctoStore,
          repo: Bandera.TestRepo,
          ecto_table_name: "bandera_flags_2"
        ]
      ]

      start_supervised!({Bandera, Keyword.put(opts, :name, :ecto_owner)})

      assert {:error,
              {{:shutdown, {:failed_to_start_child, Bandera.Instance.Registrar, reason}}, _}} =
               start_supervised({Bandera, Keyword.put(opts, :name, :ecto_intruder)})

      assert reason ==
               {:storage_conflict, {EctoStore, db(), nil, "bandera_flags_2"}, :ecto_owner}

      assert_raise ArgumentError, fn -> Config.get(:ecto_intruder) end
    end

    test "a second repo module on the same database and table is refused too" do
      table = [adapter: EctoStore, ecto_table_name: "bandera_flags_2"]

      start_supervised!(
        {Bandera, name: :ecto_owner, persistence: [{:repo, Bandera.TestRepo} | table]}
      )

      assert {:error, {{:shutdown, {:failed_to_start_child, _, reason}}, _}} =
               start_supervised(
                 {Bandera,
                  name: :ecto_alias, persistence: [{:repo, Bandera.TestRepoAlias} | table]}
               )

      assert {:storage_conflict, {EctoStore, _, nil, "bandera_flags_2"}, :ecto_owner} = reason
    end

    test "different tables on the same repo coexist" do
      opts_a = [
        persistence: [
          adapter: EctoStore,
          repo: Bandera.TestRepo,
          ecto_table_name: "bandera_flags"
        ]
      ]

      opts_b = [
        persistence: [
          adapter: EctoStore,
          repo: Bandera.TestRepo,
          ecto_table_name: "bandera_flags_2"
        ]
      ]

      start_supervised!({Bandera, Keyword.put(opts_a, :name, :ecto_table_a)})
      start_supervised!({Bandera, Keyword.put(opts_b, :name, :ecto_table_b)})
    end

    test "the same table under different prefixes coexists" do
      opts_a = [
        persistence: [
          adapter: EctoStore,
          repo: Bandera.TestRepo,
          ecto_table_name: "bandera_flags_2",
          prefix: "tenant_a"
        ]
      ]

      opts_b = [
        persistence: [
          adapter: EctoStore,
          repo: Bandera.TestRepo,
          ecto_table_name: "bandera_flags_2",
          prefix: "tenant_b"
        ]
      ]

      start_supervised!({Bandera, Keyword.put(opts_a, :name, :ecto_prefix_a)})
      start_supervised!({Bandera, Keyword.put(opts_b, :name, :ecto_prefix_b)})
    end
  end

  defp db, do: EctoStore.database_location(Bandera.TestRepo)
end
