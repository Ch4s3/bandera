defmodule Bandera.Store.TwoLevel do
  @moduledoc """
  Default store: an ETS cache in front of a persistent adapter. Whether the cache
  is consulted is decided per-call from the runtime `Bandera.Config` snapshot
  (read from `:persistent_term`), so caching can be toggled at runtime with no
  recompilation. The persistent adapter is also runtime-selected.

  ## Examples

      iex> alias Bandera.Store.TwoLevel
      iex> TwoLevel.put(:demo, Bandera.Gate.new(:boolean, true))
      iex> {:ok, flag} = TwoLevel.lookup(:demo)
      iex> flag.gates
      [%Bandera.Gate{type: :boolean, for: nil, enabled: true}]
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
          with {:ok, flag} <- persistent_get(flag_name) do
            {:ok, Cache.put(flag)}
          end
      end
    else
      persistent_get(flag_name)
    end
  end

  @impl Bandera.Store
  def put(flag_name, gate) do
    with {:ok, flag} <- persistent_put(flag_name, gate) do
      refresh_cache(flag_name, flag)
      Bandera.Notifications.publish_change(flag_name)
      {:ok, flag}
    end
  end

  @impl Bandera.Store
  def delete(flag_name, gate) do
    with {:ok, flag} <- persistent_delete(flag_name, gate) do
      refresh_cache(flag_name, flag)
      Bandera.Notifications.publish_change(flag_name)
      {:ok, flag}
    end
  end

  @impl Bandera.Store
  def delete(flag_name) do
    with {:ok, flag} <- persistent_delete(flag_name) do
      refresh_cache(flag_name, flag)
      Bandera.Notifications.publish_change(flag_name)
      {:ok, flag}
    end
  end

  @impl Bandera.Store
  def all_flags do
    Bandera.Telemetry.span([:persistence, :all_flags], %{}, fn ->
      {persistent().all_flags(), %{}}
    end)
  end

  @impl Bandera.Store
  def all_flag_names do
    Bandera.Telemetry.span([:persistence, :all_flag_names], %{}, fn ->
      {persistent().all_flag_names(), %{}}
    end)
  end

  defp persistent, do: Config.persistence_adapter()

  # point-in-time: emitted only when the persistent adapter is actually read
  # (i.e. on a cache miss), matching fun_with_flags' read semantics.
  defp persistent_get(flag_name) do
    result = persistent().get(flag_name)
    Bandera.Telemetry.event([:persistence, :get], %{flag_name: flag_name})
    result
  end

  defp persistent_put(flag_name, gate) do
    Bandera.Telemetry.span([:persistence, :put], %{flag_name: flag_name, gate: gate}, fn ->
      {persistent().put(flag_name, gate), %{}}
    end)
  end

  defp persistent_delete(flag_name, gate) do
    Bandera.Telemetry.span([:persistence, :delete], %{flag_name: flag_name, gate: gate}, fn ->
      {persistent().delete(flag_name, gate), %{}}
    end)
  end

  defp persistent_delete(flag_name) do
    Bandera.Telemetry.span([:persistence, :delete], %{flag_name: flag_name}, fn ->
      {persistent().delete(flag_name), %{}}
    end)
  end

  # Keep the cache consistent on writes: refresh when enabled, otherwise drop any
  # stale entry so it can't reappear if the cache is later re-enabled.
  defp refresh_cache(flag_name, flag) do
    if Config.cache_enabled?(), do: Cache.put(flag), else: Cache.bust(flag_name)
  end
end
