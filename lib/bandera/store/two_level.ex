defmodule Bandera.Store.TwoLevel do
  @moduledoc """
  Default store: an ETS cache in front of a persistent adapter. Whether the cache
  is consulted is decided per-call from the runtime `Bandera.Config` snapshot
  (read from `:persistent_term`), so caching can be toggled at runtime with no
  recompilation. The persistent adapter is also runtime-selected.
  """

  @behaviour Bandera.Store

  alias Bandera.Config
  alias Bandera.Store.Cache

  @impl Bandera.Store
  def lookup(flag_name) do
    if Config.cache_enabled?() do
      case Cache.get(flag_name) do
        {:ok, flag} ->
          {:ok, flag}

        {:miss, _reason} ->
          with {:ok, flag} <- persistent().get(flag_name) do
            {:ok, Cache.put(flag)}
          end
      end
    else
      persistent().get(flag_name)
    end
  end

  @impl Bandera.Store
  def put(flag_name, gate) do
    with {:ok, flag} <- persistent().put(flag_name, gate) do
      refresh_cache(flag_name, flag)
      {:ok, flag}
    end
  end

  @impl Bandera.Store
  def delete(flag_name, gate) do
    with {:ok, flag} <- persistent().delete(flag_name, gate) do
      refresh_cache(flag_name, flag)
      {:ok, flag}
    end
  end

  @impl Bandera.Store
  def delete(flag_name) do
    with {:ok, flag} <- persistent().delete(flag_name) do
      refresh_cache(flag_name, flag)
      {:ok, flag}
    end
  end

  @impl Bandera.Store
  def all_flags, do: persistent().all_flags()

  @impl Bandera.Store
  def all_flag_names, do: persistent().all_flag_names()

  defp persistent, do: Config.persistence_adapter()

  # Keep the cache consistent on writes: refresh when enabled, otherwise drop any
  # stale entry so it can't reappear if the cache is later re-enabled.
  defp refresh_cache(flag_name, flag) do
    if Config.cache_enabled?(), do: Cache.put(flag), else: Cache.bust(flag_name)
  end
end
