defmodule Bandera.Config do
  @moduledoc """
  Resolves all Bandera settings at RUNTIME and caches them in a `:persistent_term`
  snapshot for cheap hot-path reads.

  This module deliberately uses NO `Application.compile_env/3`. Every value is read
  from `Application.get_env/3` and can be changed at runtime via `reload/0`, with no
  dependency recompilation. (Fixes fun_with_flags#122.)
  """

  @pt_key {__MODULE__, :snapshot}

  @default_cache [enabled: true, ttl: 900]
  @default_persistence [adapter: Bandera.Store.Persistent.Memory]
  @default_store Bandera.Store.TwoLevel
  @default_notifications [enabled: false, adapter: Bandera.Notifications.Redis]
  @default_dashboard [group_separator: "_", theme: :standalone]

  @type snapshot :: %{
          store: module,
          cache_enabled?: boolean,
          cache_ttl: non_neg_integer,
          persistence_adapter: module,
          persistence: keyword,
          notifications_enabled?: boolean,
          notifications_adapter: module,
          notifications: keyword,
          group_separator: String.t() | nil,
          theme: :standalone | :daisyui
        }

  @doc "Re-read application env and rewrite the persistent_term snapshot."
  @spec reload() :: :ok
  def reload do
    :persistent_term.put(@pt_key, build_snapshot())
    :ok
  end

  @doc "Return the current snapshot, seeding it lazily if not yet present."
  @spec snapshot() :: snapshot
  def snapshot do
    case :persistent_term.get(@pt_key, nil) do
      nil ->
        # NOTE: concurrent cold-start races are benign — both writes produce identical snapshots.
        snap = build_snapshot()
        :persistent_term.put(@pt_key, snap)
        snap

      snap ->
        snap
    end
  end

  @doc "The active store module (default `Bandera.Store.TwoLevel`)."
  @spec store() :: module
  def store, do: snapshot().store

  @doc "Whether the read cache is enabled (default `true`)."
  @spec cache_enabled?() :: boolean
  def cache_enabled?, do: snapshot().cache_enabled?

  @doc "Cache time-to-live in seconds (default `900`)."
  @spec cache_ttl() :: non_neg_integer
  def cache_ttl, do: snapshot().cache_ttl

  @doc "The persistence adapter module (default `Bandera.Store.Persistent.Memory`)."
  @spec persistence_adapter() :: module
  def persistence_adapter, do: snapshot().persistence_adapter

  @doc "The full persistence keyword config (adapter plus adapter-specific options)."
  @spec persistence() :: keyword
  def persistence, do: snapshot().persistence

  @doc "The SQL table name used by the Ecto adapter (default `\"bandera_flags\"`)."
  @spec ecto_table_name() :: String.t()
  def ecto_table_name, do: Keyword.get(persistence(), :ecto_table_name, "bandera_flags")

  @doc "Whether cross-node cache-busting notifications are enabled (default `false`)."
  @spec notifications_enabled?() :: boolean
  def notifications_enabled?, do: snapshot().notifications_enabled?

  @doc "The notifications adapter module (default `Bandera.Notifications.Redis`)."
  @spec notifications_adapter() :: module
  def notifications_adapter, do: snapshot().notifications_adapter

  @doc "The full notifications keyword config (adapter plus adapter-specific options)."
  @spec notifications() :: keyword
  def notifications, do: snapshot().notifications

  @doc "The dashboard's flag-grouping separator (default `\"_\"`; `nil` disables grouping)."
  @spec group_separator() :: String.t() | nil
  def group_separator, do: snapshot().group_separator

  @doc """
  The dashboard's styling theme (default `:standalone`).

  `:standalone` inlines a self-contained stylesheet; `:daisyui` emits daisyUI
  classes and no stylesheet, for apps that build daisyUI themselves. Any other
  value normalizes to `:standalone`.
  """
  @spec theme() :: :standalone | :daisyui
  def theme, do: snapshot().theme

  @doc "Generate a random per-node id used to ignore self-published change notifications."
  @spec build_unique_id() :: String.t()
  def build_unique_id, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp build_snapshot do
    cache = Keyword.merge(@default_cache, Application.get_env(:bandera, :cache, []))

    persistence =
      Keyword.merge(@default_persistence, Application.get_env(:bandera, :persistence, []))

    notifications =
      Keyword.merge(
        @default_notifications,
        Application.get_env(:bandera, :cache_bust_notifications, [])
      )

    dashboard =
      Keyword.merge(@default_dashboard, Application.get_env(:bandera, :dashboard, []))

    %{
      store: Application.get_env(:bandera, :store, @default_store),
      cache_enabled?: Keyword.fetch!(cache, :enabled),
      cache_ttl: Keyword.fetch!(cache, :ttl),
      persistence_adapter: Keyword.fetch!(persistence, :adapter),
      persistence: persistence,
      notifications_enabled?: Keyword.fetch!(notifications, :enabled),
      notifications_adapter: Keyword.fetch!(notifications, :adapter),
      notifications: notifications,
      group_separator: Keyword.fetch!(dashboard, :group_separator),
      theme: normalize_theme(Keyword.fetch!(dashboard, :theme))
    }
  end

  defp normalize_theme(:daisyui), do: :daisyui
  defp normalize_theme(_), do: :standalone
end
