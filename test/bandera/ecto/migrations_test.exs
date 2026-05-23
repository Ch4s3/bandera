defmodule Bandera.Ecto.MigrationsTest do
  use ExUnit.Case, async: false

  setup do
    Bandera.TestRepo.query!("DELETE FROM bandera_flags")
    :ok
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
    %{rows: rows} = Bandera.TestRepo.query!("PRAGMA table_info(bandera_flags)")
    names = Enum.map(rows, fn row -> Enum.at(row, 1) end)
    assert "value" in names
  end
end
