defmodule Bandera.Store.TwoLevel do
  @moduledoc """
  Default store: an ETS cache in front of a persistent adapter, per instance.
  Whether the cache is consulted is decided per-call from the instance's
  `Bandera.Config` (read from `:persistent_term`), so caching can be toggled at
  runtime with no recompilation. The persistent adapter is also runtime-selected.

  ## Examples

      iex> alias Bandera.Store.TwoLevel
      iex> conf = Bandera.Config.get()
      iex> TwoLevel.put(conf, :demo, Bandera.Gate.new(:boolean, true))
      iex> {:ok, flag} = TwoLevel.lookup(conf, :demo)
      iex> flag.gates
      [%Bandera.Gate{type: :boolean, for: nil, enabled: true}]
  """

  @behaviour Bandera.Store

  alias Bandera.Config
  alias Bandera.Gate
  alias Bandera.Store.Cache
  alias Bandera.Store.Persistent

  @impl Bandera.Store
  def lookup(%Config{cache_enabled?: true} = conf, flag_name) do
    case Cache.get(conf, flag_name) do
      {:ok, flag} ->
        {:ok, flag}

      {:miss, _reason} ->
        with {:ok, flag} <- persistent_get(conf, flag_name) do
          {:ok, Cache.put(conf, flag)}
        end
    end
  end

  def lookup(%Config{} = conf, flag_name), do: persistent_get(conf, flag_name)

  @impl Bandera.Store
  def put(%Config{} = conf, flag_name, gate) do
    with {:ok, flag} <- persistent_put(conf, flag_name, gate) do
      refresh_cache(conf, flag_name, flag)
      Bandera.Notifications.publish_change(conf, flag_name)
      {:ok, flag}
    end
  end

  @impl Bandera.Store
  def delete(%Config{} = conf, flag_name, gate) do
    with {:ok, flag} <- persistent_delete(conf, flag_name, gate) do
      refresh_cache(conf, flag_name, flag)
      Bandera.Notifications.publish_change(conf, flag_name)
      {:ok, flag}
    end
  end

  @impl Bandera.Store
  def delete(%Config{} = conf, flag_name) do
    with {:ok, flag} <- persistent_delete(conf, flag_name) do
      refresh_cache(conf, flag_name, flag)
      Bandera.Notifications.publish_change(conf, flag_name)
      {:ok, flag}
    end
  end

  def delete(flag_name, %Gate{} = gate) when is_atom(flag_name),
    do: delete(Config.get(), flag_name, gate)

  @impl Bandera.Store
  def all_flags(%Config{} = conf) do
    Bandera.Telemetry.span([:persistence, :all_flags], %{instance: conf.name}, fn ->
      {Persistent.all_flags(conf), %{}}
    end)
  end

  @impl Bandera.Store
  def all_flag_names(%Config{} = conf) do
    Bandera.Telemetry.span([:persistence, :all_flag_names], %{instance: conf.name}, fn ->
      {Persistent.all_flag_names(conf), %{}}
    end)
  end

  # point-in-time: emitted only when the persistent adapter is actually read
  # (i.e. on a cache miss), matching fun_with_flags' read semantics.
  defp persistent_get(conf, flag_name) do
    result = Persistent.get(conf, flag_name)
    Bandera.Telemetry.event([:persistence, :get], %{flag_name: flag_name, instance: conf.name})
    result
  end

  defp persistent_put(conf, flag_name, gate) do
    meta = %{flag_name: flag_name, gate: gate, instance: conf.name}

    Bandera.Telemetry.span([:persistence, :put], meta, fn ->
      {Persistent.put(conf, flag_name, gate), %{}}
    end)
  end

  defp persistent_delete(conf, flag_name, gate) do
    meta = %{flag_name: flag_name, gate: gate, instance: conf.name}

    Bandera.Telemetry.span([:persistence, :delete], meta, fn ->
      {Persistent.delete(conf, flag_name, gate), %{}}
    end)
  end

  defp persistent_delete(conf, flag_name) do
    meta = %{flag_name: flag_name, instance: conf.name}

    Bandera.Telemetry.span([:persistence, :delete], meta, fn ->
      {Persistent.delete(conf, flag_name), %{}}
    end)
  end

  # Keep the cache consistent on writes: refresh when enabled, otherwise drop any
  # stale entry so it can't reappear if the cache is later re-enabled.
  defp refresh_cache(%Config{cache_enabled?: true} = conf, _flag_name, flag),
    do: Cache.put(conf, flag)

  defp refresh_cache(conf, flag_name, _flag), do: Cache.bust(conf, flag_name)
  # ---- default-instance forms (backward compatibility) ----
  # The pre-instance arities, acting on the default instance (the
  # `delete(flag_name, gate)` form sits with the `delete/2` callback above).

  @doc false

  @spec lookup(atom) :: {:ok, Bandera.Flag.t()} | {:error, term}
  def lookup(flag_name) when is_atom(flag_name), do: lookup(Config.get(), flag_name)

  @doc false

  @spec put(atom, Bandera.Gate.t()) :: {:ok, Bandera.Flag.t()} | {:error, term}
  def put(flag_name, %Gate{} = gate) when is_atom(flag_name),
    do: put(Config.get(), flag_name, gate)

  @doc false

  @spec delete(atom) :: {:ok, Bandera.Flag.t()} | {:error, term}
  def delete(flag_name) when is_atom(flag_name), do: delete(Config.get(), flag_name)

  @doc false

  @spec all_flags() :: {:ok, [Bandera.Flag.t()]} | {:error, term}
  def all_flags, do: all_flags(Config.get())

  @doc false

  @spec all_flag_names() :: {:ok, [atom]} | {:error, term}
  def all_flag_names, do: all_flag_names(Config.get())
end
