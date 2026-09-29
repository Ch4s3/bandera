defmodule Bandera.RaisingNotifier do
  @moduledoc "Test stub: a notifier whose `publish_change/2` always raises."
  @behaviour Bandera.Notifications

  @impl true
  def publish_change(_conf, _flag), do: raise("boom")

  @impl true
  def unique_id(_conf), do: "raising"
end
