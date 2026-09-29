defmodule Bandera.TestNotifier do
  @moduledoc """
  Test stub: records published changes by messaging a configured pid. Has no
  process (no `child_spec/1`), so an instance using it starts no notifier child.
  """
  @behaviour Bandera.Notifications

  @impl true
  def publish_change(_conf, flag_name) do
    case Application.get_env(:bandera, :test_notifier_pid) do
      pid when is_pid(pid) -> send(pid, {:published, flag_name})
      _ -> :ok
    end

    :ok
  end

  @impl true
  def unique_id(_conf), do: "test-notifier"
end
