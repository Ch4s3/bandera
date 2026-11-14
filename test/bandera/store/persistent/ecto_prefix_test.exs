defmodule Bandera.Store.Persistent.EctoPrefixTest do
  use ExUnit.Case, async: false

  alias Bandera.Store.Persistent.Ecto, as: EctoStore
  alias Bandera.Store.Persistent.EctoPrefixTest.RecordingRepo

  # SQLite (the test repo) has no schemas, and ecto_sqlite3 refuses a prefix,
  # so a repo double records the options each call receives.
  defmodule RecordingRepo do
    @moduledoc false

    @spec all(term, keyword) :: list
    def all(query, opts), do: record(:all, opts, [], query)

    @spec delete_all(term, keyword) :: {non_neg_integer, nil}
    def delete_all(query, opts), do: record(:delete_all, opts, {0, nil}, query)

    @spec insert_all(term, list, keyword) :: {non_neg_integer, nil}
    def insert_all(source, _rows, opts), do: record(:insert_all, opts, {1, nil}, source)

    @spec transaction((-> term)) :: {:ok, term}
    def transaction(fun), do: {:ok, fun.()}

    defp record(call, opts, result, _query) do
      send(self(), {:repo_call, call, Keyword.take(opts, [:prefix])})
      result
    end
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:bandera, :persistence)
      Bandera.reload_config()
    end)
  end

  defp configure(extra) do
    Application.put_env(
      :bandera,
      :persistence,
      [adapter: EctoStore, repo: RecordingRepo] ++ extra
    )

    Bandera.reload_config()
  end

  defp exercise_store do
    EctoStore.get(:f)
    EctoStore.put(:f, Bandera.Gate.new(:boolean, true))
    EctoStore.put(:f, Bandera.Gate.new(:actor, %{id: 1}, true))
    EctoStore.put(:f, Bandera.Gate.new(:percentage_of_time, 0.5))
    EctoStore.delete(:f, Bandera.Gate.new(:actor, %{id: 1}, true))
    EctoStore.delete(:f, Bandera.Gate.new(:percentage_of_time, 0.5))
    EctoStore.delete(:f)
    EctoStore.all_flags()
    EctoStore.all_flag_names()

    table = :bandera_usage_prefix_probe
    :ets.new(table, [:named_table, :public, :set])
    :ets.insert(table, {:used_flag, DateTime.utc_now()})
    Bandera.Usage.Ecto.flush_all(table)
    Bandera.Usage.Ecto.load_into_ets(table)

    calls()
  end

  defp calls do
    receive do
      {:repo_call, call, opts} -> [{call, opts} | calls()]
    after
      0 -> []
    end
  end

  test "with persistence prefix set, every store and usage call is made in that schema" do
    configure(prefix: "flags_schema")

    calls = exercise_store()

    assert length(calls) >= 12

    assert Enum.all?(calls, fn {_call, opts} -> opts == [prefix: "flags_schema"] end),
           inspect(calls)

    assert {:all, [prefix: "flags_schema"]} in calls
    assert {:delete_all, [prefix: "flags_schema"]} in calls
    assert {:insert_all, [prefix: "flags_schema"]} in calls
  end

  test "without a prefix, calls carry none, so the repo's default schema applies" do
    configure([])

    calls = exercise_store()

    assert calls != []
    assert Enum.all?(calls, fn {_call, opts} -> opts == [] end), inspect(calls)
  end

  test "the configured prefix is read from persistence" do
    configure(prefix: "flags_schema")
    assert Bandera.Config.ecto_prefix() == "flags_schema"

    configure([])
    assert Bandera.Config.ecto_prefix() == nil
  end
end
