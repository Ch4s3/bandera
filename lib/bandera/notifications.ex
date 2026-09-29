defmodule Bandera.Notifications do
  @moduledoc """
  Cross-node cache-busting notifications.

  When the `Bandera.Store.TwoLevel` store writes a flag, it calls
  `publish_change/2`. If the instance has notifications enabled, its configured
  adapter broadcasts the change to all nodes; each node's notifier for that same
  instance busts its local cache entry for that flag (ignoring changes it
  published itself). Disabled by default.

      config :bandera,
        cache_bust_notifications: [
          enabled: true,
          adapter: Bandera.Notifications.Redis,
          redis: [host: "localhost", port: 6379]
        ]

  Each instance publishes on its own channel/topic (`"bandera:changes"` for the
  default instance, `"bandera:{MyApp.Flags}:changes"` for a named one), so a change
  in one instance never busts another instance's cache.

  An adapter is started under its instance's supervisor as `{adapter, conf}` and
  should register under `conf.notifier`. Adapters written before instances existed
  (`publish_change/1`, `unique_id/0`) keep working: they are started with no
  arguments and called with the old arities.
  """

  alias Bandera.Config

  require Logger

  @doc "Broadcasts a flag change to other nodes so they bust their local cache entry."
  @callback publish_change(Config.t(), flag_name :: atom) :: :ok | {:error, term}

  @doc "Returns this node's stable per-node id, used to ignore self-published changes."
  @callback unique_id(Config.t()) :: String.t()

  @doc """
  Publish a flag change for the default instance (backward compatible). See
  `publish_change/2`.
  """
  @spec publish_change(atom) :: :ok | {:error, term}
  def publish_change(flag_name) when is_atom(flag_name),
    do: publish_change(Config.get(), flag_name)

  @doc """
  Publish a flag change to other nodes of `conf`'s instance (no-op when the
  instance's notifications are disabled, best-effort when enabled).
  """
  @spec publish_change(Config.t(), atom) :: :ok | {:error, term}
  def publish_change(%Config{notifications_enabled?: false}, _flag_name), do: :ok

  def publish_change(%Config{} = conf, flag_name) do
    dispatch_publish(conf, flag_name)
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

  defp dispatch_publish(
         %Config{notifications_legacy?: false, notifications_adapter: a} = conf,
         f
       ),
       do: a.publish_change(conf, f)

  defp dispatch_publish(%Config{notifications_adapter: a}, f), do: a.publish_change(f)

  @doc """
  The channel/topic `conf`'s instance publishes changes on: `"bandera:changes"`
  for the default instance, `"bandera:{MyApp.Flags}:changes"` for a named one.
  """
  @spec topic(Config.t()) :: String.t()
  def topic(%Config{namespace: namespace}), do: namespace <> ":changes"

  @doc false
  # The child spec for `conf`'s notifier (started by the instance supervisor).
  @spec child_spec_for(Config.t()) :: Supervisor.child_spec() | module | {module, Config.t()}
  def child_spec_for(%Config{notifications_legacy?: true, notifications_adapter: a}), do: a
  def child_spec_for(%Config{notifications_adapter: a} = conf), do: {a, conf}
end
