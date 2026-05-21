defmodule Bandera.Notifications do
  @moduledoc """
  Cross-node cache-busting notifications.

  When the `Bandera.Store.TwoLevel` store writes a flag, it calls
  `publish_change/1`. If notifications are enabled, the configured adapter
  broadcasts the change to all nodes; each node's notifier busts its local cache
  entry for that flag (ignoring changes it published itself). Disabled by default.

      config :bandera,
        cache_bust_notifications: [
          enabled: true,
          adapter: Bandera.Notifications.Redis,
          redis: [host: "localhost", port: 6379]
        ]
  """

  @callback publish_change(flag_name :: atom) :: :ok | {:error, term}
  @callback unique_id() :: String.t()

  @doc "Publish a flag change to other nodes (no-op when notifications are disabled)."
  @spec publish_change(atom) :: :ok | {:error, term}
  def publish_change(flag_name) do
    if Bandera.Config.notifications_enabled?() do
      Bandera.Config.notifications_adapter().publish_change(flag_name)
    else
      :ok
    end
  end
end
