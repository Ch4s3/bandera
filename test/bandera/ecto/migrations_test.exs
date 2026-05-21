defmodule Bandera.Ecto.MigrationsTest do
  use ExUnit.Case, async: false

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
end
