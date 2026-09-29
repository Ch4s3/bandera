defmodule Bandera.Ecto.MigrationsTest do
  use ExUnit.Case, async: false

  defmodule UpgradeV2Migration do
    use Ecto.Migration

    @spec up() :: :ok
    def up, do: Bandera.Ecto.Migrations.upgrade_v2()
  end

  setup do
    Bandera.TestRepo.query!("DELETE FROM bandera_flags")
    Bandera.TestRepo.query!("DELETE FROM bandera_usage")
    :ok
  end

  defp column_names(table) do
    Bandera.TestRepo
    |> Ecto.Adapters.SQL.query!("PRAGMA table_info(#{table})")
    |> Map.fetch!(:rows)
    |> Enum.map(fn row -> Enum.at(row, 1) end)
  end

  test "the migration created the flags table with the expected columns" do
    %{rows: rows} =
      Bandera.TestRepo.query!("SELECT flag_name, gate_type, target, enabled FROM bandera_flags")

    assert rows == []
  end

  test "the unique index exists" do
    %{rows: rows} =
      Bandera.TestRepo.query!(
        "SELECT name FROM sqlite_master WHERE type='index' AND name='bandera_flags_flag_name_gate_target_idx'"
      )

    assert rows == [["bandera_flags_flag_name_gate_target_idx"]]
  end

  test "the flags table has a nullable value column (schema v2)" do
    assert "value" in column_names("bandera_flags")
  end

  test "up/0 also created the usage table (new-install path)" do
    %{rows: rows} =
      Bandera.TestRepo.query!("SELECT flag_name, last_evaluated_at FROM bandera_usage")

    assert rows == []
  end

  test "up_usage/0 is idempotent (safe to re-run on an existing install)" do
    # The table already exists from the suite's migration; re-running must not raise.
    defmodule UsageMigration do
      use Ecto.Migration
      def up, do: Bandera.Ecto.Migrations.up_usage()
    end

    assert :ok =
             Ecto.Migrator.up(Bandera.TestRepo, 20_260_701_000_000, UsageMigration, log: false)

    on_exit(fn ->
      Bandera.TestRepo.query!("DELETE FROM schema_migrations WHERE version = 20260701000000")
    end)
  end

  test "upgrade_v2/0 adds the value column to an existing v1 table" do
    table = "bandera_flags_v1_upgrade_test"

    Bandera.TestRepo.query!("""
    CREATE TABLE #{table} (
      id INTEGER PRIMARY KEY,
      flag_name TEXT NOT NULL,
      gate_type TEXT NOT NULL,
      target TEXT NOT NULL,
      enabled BOOLEAN NOT NULL
    )
    """)

    previous = Application.get_env(:bandera, :persistence, [])
    Application.put_env(:bandera, :persistence, Keyword.put(previous, :ecto_table_name, table))
    Bandera.reload_config()

    on_exit(fn ->
      Application.put_env(:bandera, :persistence, previous)
      Bandera.reload_config()
      Bandera.TestRepo.query!("DROP TABLE IF EXISTS #{table}")
    end)

    refute "value" in column_names(table)

    Ecto.Migrator.run(
      Bandera.TestRepo,
      [{20_260_201_000_000, UpgradeV2Migration}],
      :up,
      all: true,
      log: false
    )

    assert "value" in column_names(table)
  end

  defmodule FixFunWithFlagsMigration do
    use Ecto.Migration

    @spec up() :: :ok
    def up, do: Bandera.Ecto.Migrations.fix_fun_with_flags_boolean_gates()
  end

  describe "fix_fun_with_flags_boolean_gates/0" do
    setup do
      Bandera.TestRepo.query!("DELETE FROM schema_migrations WHERE version = 20260601000001")

      on_exit(fn ->
        Bandera.TestRepo.query!("DELETE FROM schema_migrations WHERE version = 20260601000001")
      end)
    end

    test "renames a lone legacy boolean row to _bandera_none" do
      Bandera.TestRepo.query!("""
      INSERT INTO bandera_flags (flag_name, gate_type, target, enabled, value)
      VALUES ('my_flag', 'boolean', 'boolean', true, NULL)
      """)

      run_fix_migration()

      %{rows: rows} =
        Bandera.TestRepo.query!(
          "SELECT target, enabled FROM bandera_flags WHERE flag_name='my_flag' AND gate_type='boolean'"
        )

      assert rows == [["_bandera_none", 1]]
    end

    test "deletes legacy row when a Bandera row already exists, keeping Bandera row's enabled value" do
      Bandera.TestRepo.query!("""
      INSERT INTO bandera_flags (flag_name, gate_type, target, enabled, value)
      VALUES ('my_flag', 'boolean', 'boolean', true, NULL),
             ('my_flag', 'boolean', '_bandera_none', false, NULL)
      """)

      run_fix_migration()

      %{rows: rows} =
        Bandera.TestRepo.query!(
          "SELECT target, enabled FROM bandera_flags WHERE flag_name='my_flag' AND gate_type='boolean'"
        )

      assert rows == [["_bandera_none", 0]]
    end

    test "does not touch actor or group rows" do
      Bandera.TestRepo.query!("""
      INSERT INTO bandera_flags (flag_name, gate_type, target, enabled, value)
      VALUES ('my_flag', 'boolean', 'boolean', true, NULL),
             ('my_flag', 'actor', 'user:1', true, NULL)
      """)

      run_fix_migration()

      %{rows: rows} =
        Bandera.TestRepo.query!(
          "SELECT gate_type, target FROM bandera_flags WHERE flag_name='my_flag' ORDER BY gate_type"
        )

      assert rows == [["actor", "user:1"], ["boolean", "_bandera_none"]]
    end

    test "is a no-op when all boolean rows already use _bandera_none" do
      Bandera.TestRepo.query!("""
      INSERT INTO bandera_flags (flag_name, gate_type, target, enabled, value)
      VALUES ('my_flag', 'boolean', '_bandera_none', true, NULL)
      """)

      run_fix_migration()

      %{rows: rows} =
        Bandera.TestRepo.query!(
          "SELECT target, enabled FROM bandera_flags WHERE flag_name='my_flag' AND gate_type='boolean'"
        )

      assert rows == [["_bandera_none", 1]]
    end

    defp run_fix_migration do
      Ecto.Migrator.run(
        Bandera.TestRepo,
        [{20_260_601_000_001, FixFunWithFlagsMigration}],
        :up,
        all: true,
        log: false
      )
    end
  end

  describe "options (:table, :usage_table, :prefix) for a named instance's own tables" do
    defmodule NamedInstanceMigration do
      use Ecto.Migration

      @spec up() :: :ok
      def up do
        Bandera.Ecto.Migrations.up(table: "named_flags", usage_table: "named_usage")
      end

      @spec down() :: :ok
      def down do
        Bandera.Ecto.Migrations.down(table: "named_flags", usage_table: "named_usage")
      end
    end

    setup do
      Ecto.Migrator.run(
        Bandera.TestRepo,
        [{20_260_801_000_000, NamedInstanceMigration}],
        :up,
        all: true,
        log: false
      )

      on_exit(fn ->
        Ecto.Migrator.run(
          Bandera.TestRepo,
          [{20_260_801_000_000, NamedInstanceMigration}],
          :down,
          all: true,
          log: false
        )
      end)

      :ok
    end

    test "up/1 creates the flags table under the given name, with its unique index" do
      %{rows: rows} =
        Bandera.TestRepo.query!("SELECT flag_name, gate_type, target, enabled FROM named_flags")

      assert rows == []
      assert "value" in column_names("named_flags")

      %{rows: rows} =
        Bandera.TestRepo.query!(
          "SELECT name FROM sqlite_master WHERE type='index' AND name='named_flags_flag_name_gate_target_idx'"
        )

      assert rows == [["named_flags_flag_name_gate_target_idx"]]
    end

    test "up/1 also creates the usage table under the given name" do
      %{rows: rows} =
        Bandera.TestRepo.query!("SELECT flag_name, last_evaluated_at FROM named_usage")

      assert rows == []
    end

    test "unspecified options still fall back to the default instance's configured names" do
      # The default-instance tables from the suite's main migration coexist untouched.
      assert Bandera.TestRepo.query!("SELECT * FROM bandera_flags").rows == []
      assert Bandera.TestRepo.query!("SELECT * FROM bandera_usage").rows == []
    end
  end

  describe "prefix option" do
    defmodule PrefixedFixMigration do
      use Ecto.Migration

      @spec up() :: :ok
      def up, do: Bandera.Ecto.Migrations.fix_fun_with_flags_boolean_gates(prefix: "tenant_a")
    end

    test "fix_fun_with_flags_boolean_gates/1 qualifies the table in its raw SQL when a prefix is given" do
      # SQLite has no schema concept, so we can't exercise a real prefixed table —
      # assert only that the generated SQL is schema-qualified: a query aimed at
      # "tenant_a.bandera_flags" fails because no such (attached) schema exists,
      # which is only possible if the table name was actually qualified.
      assert_raise Exqlite.Error, ~r/unknown database tenant_a|no such table/, fn ->
        Ecto.Migrator.run(
          Bandera.TestRepo,
          [{20_260_801_000_001, PrefixedFixMigration}],
          :up,
          all: true,
          log: false
        )
      end

      Bandera.TestRepo.query!("DELETE FROM schema_migrations WHERE version = 20260801000001")
    end
  end
end
