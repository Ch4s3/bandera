defmodule Bandera.RaisingNotifier do
  @moduledoc "Test stub: a notifier whose `publish_change/1` always raises."
  @behaviour Bandera.Notifications

  @impl true
  def publish_change(_flag), do: raise("boom")

  @impl true
  def unique_id, do: "raising"
end
