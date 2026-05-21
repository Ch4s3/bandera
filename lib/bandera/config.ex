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

  @type snapshot :: %{
          store: module,
          cache_enabled?: boolean,
          cache_ttl: non_neg_integer,
          persistence_adapter: module,
          persistence: keyword
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

  @spec store() :: module
  def store, do: snapshot().store

  @spec cache_enabled?() :: boolean
  def cache_enabled?, do: snapshot().cache_enabled?

  @spec cache_ttl() :: non_neg_integer
  def cache_ttl, do: snapshot().cache_ttl

  @spec persistence_adapter() :: module
  def persistence_adapter, do: snapshot().persistence_adapter

  @spec persistence() :: keyword
  def persistence, do: snapshot().persistence

  defp build_snapshot do
    cache = Keyword.merge(@default_cache, Application.get_env(:bandera, :cache, []))

    persistence =
      Keyword.merge(@default_persistence, Application.get_env(:bandera, :persistence, []))

    %{
      store: Application.get_env(:bandera, :store, @default_store),
      cache_enabled?: Keyword.fetch!(cache, :enabled),
      cache_ttl: Keyword.fetch!(cache, :ttl),
      persistence_adapter: Keyword.fetch!(persistence, :adapter),
      persistence: persistence
    }
  end
end
