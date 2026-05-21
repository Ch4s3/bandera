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

  require Logger

  @doc "Broadcasts a flag change to other nodes so they bust their local cache entry."
  @callback publish_change(flag_name :: atom) :: :ok | {:error, term}

  @doc "Returns this node's stable per-node id, used to ignore self-published changes."
  @callback unique_id() :: String.t()

  @doc "Publish a flag change to other nodes (no-op when notifications are disabled, best-effort when enabled)."
  @spec publish_change(atom) :: :ok | {:error, term}
  def publish_change(flag_name) do
    if Bandera.Config.notifications_enabled?() do
      try do
        Bandera.Config.notifications_adapter().publish_change(flag_name)
      rescue
        error ->
          Logger.warning(
            "[Bandera] notification publish failed for #{inspect(flag_name)}: #{Exception.message(error)}"
          )

          {:error, error}
      catch
        :exit, reason ->
          Logger.warning(
            "[Bandera] notification publish exited for #{inspect(flag_name)}: #{inspect(reason)}"
          )

          {:error, {:exit, reason}}
      end
    else
      :ok
    end
  end
end
