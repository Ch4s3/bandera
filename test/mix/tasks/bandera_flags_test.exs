defmodule Mix.Tasks.Bandera.FlagsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  @task Mix.Tasks.Bandera.Flags

  describe "--instance" do
    test "lists the named instance's flags, given a module name" do
      start_supervised!(
        {Bandera,
         name: Bandera.MixTaskFlagsTest.Instance,
         persistence: [adapter: Bandera.Store.Persistent.Memory]}
      )

      start_supervised!(
        {Bandera,
         name: Bandera.MixTaskFlagsTest.OtherInstance,
         persistence: [adapter: Bandera.Store.Persistent.Memory]}
      )

      {:ok, true} = Bandera.enable(:only_in_named, instance: Bandera.MixTaskFlagsTest.Instance)

      {:ok, true} =
        Bandera.enable(:only_in_other, instance: Bandera.MixTaskFlagsTest.OtherInstance)

      output =
        capture_io(fn -> @task.run(["--instance", "Bandera.MixTaskFlagsTest.Instance"]) end)

      assert output =~ "only_in_named"
      refute output =~ "only_in_other"
    end

    test "parses a plain atom instance given as :name" do
      start_supervised!(
        {Bandera,
         name: :mix_task_flags_plain_atom, persistence: [adapter: Bandera.Store.Persistent.Memory]}
      )

      {:ok, true} = Bandera.enable(:atom_named_flag, instance: :mix_task_flags_plain_atom)

      output = capture_io(fn -> @task.run(["--instance", ":mix_task_flags_plain_atom"]) end)

      assert output =~ "atom_named_flag"
    end

    test "warns when --stale is given and the instance's own Usage tracker is not running" do
      start_supervised!(
        {Bandera,
         name: :mix_task_flags_no_usage, persistence: [adapter: Bandera.Store.Persistent.Memory]}
      )

      output =
        capture_io(fn -> @task.run(["--instance", ":mix_task_flags_no_usage", "--stale"]) end)

      assert output =~ "Bandera.Usage is not running"
    end

    test "does not warn when the instance's own Usage tracker is running" do
      start_supervised!(
        {Bandera,
         name: :mix_task_flags_with_usage, persistence: [adapter: Bandera.Store.Persistent.Memory]}
      )

      start_supervised!({Bandera.Usage, instance: :mix_task_flags_with_usage})

      output =
        capture_io(fn -> @task.run(["--instance", ":mix_task_flags_with_usage", "--stale"]) end)

      refute output =~ "is not running"
    end
  end
end
