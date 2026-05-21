defmodule Bandera do
  @moduledoc """
  Runtime-configured feature flags, API-compatible with fun_with_flags.

  The active store is resolved at runtime (`Bandera.Store.active/0`), so nothing
  about persistence or caching is fixed at compile time.
  """

  alias Bandera.Flag
  alias Bandera.Gate
  alias Bandera.Store
  require Logger

  @doc "Re-read application env into the runtime config snapshot."
  @spec reload_config() :: :ok
  defdelegate reload_config, to: Bandera.Config, as: :reload

  # ---- enabled? ----

  @spec enabled?(atom, keyword) :: boolean
  def enabled?(flag_name, options \\ [])

  def enabled?(flag_name, []) when is_atom(flag_name) do
    result =
      case Store.active().lookup(flag_name) do
        {:ok, flag} -> Flag.enabled?(flag)
        error -> lookup_failed(flag_name, error)
      end

    track_enabled?(flag_name, [], result)
  end

  def enabled?(flag_name, for: nil), do: enabled?(flag_name)

  def enabled?(flag_name, for: item) when is_atom(flag_name) do
    result =
      case Store.active().lookup(flag_name) do
        {:ok, flag} -> Flag.enabled?(flag, for: item)
        error -> lookup_failed(flag_name, error)
      end

    track_enabled?(flag_name, [for: item], result)
  end

  defp track_enabled?(flag_name, options, result) do
    Bandera.Telemetry.event([:enabled?], %{flag_name: flag_name, options: options, result: result})

    result
  end

  # ---- enable ----

  @spec enable(atom, keyword) :: {:ok, boolean} | {:error, term}
  def enable(flag_name, options \\ [])

  def enable(flag_name, options) when is_atom(flag_name) do
    Bandera.Telemetry.span([:enable], %{flag_name: flag_name, options: options}, fn ->
      result = do_enable(flag_name, options)
      {result, %{result: result}}
    end)
  end

  defp do_enable(flag_name, []) when is_atom(flag_name),
    do: put_and_verify(flag_name, Gate.new(:boolean, true), [])

  defp do_enable(flag_name, for_actor: nil), do: do_enable(flag_name, [])

  defp do_enable(flag_name, for_actor: actor) when is_atom(flag_name),
    do: put_and_verify(flag_name, Gate.new(:actor, actor, true), for: actor)

  defp do_enable(flag_name, for_group: nil), do: do_enable(flag_name, [])

  defp do_enable(flag_name, for_group: group_name) when is_atom(flag_name),
    do: put_constant(flag_name, Gate.new(:group, group_name, true), true)

  defp do_enable(flag_name, for_percentage_of: {:time, ratio}) when is_atom(flag_name),
    do: put_constant(flag_name, Gate.new(:percentage_of_time, ratio), true)

  defp do_enable(flag_name, for_percentage_of: {:actors, ratio}) when is_atom(flag_name),
    do: put_constant(flag_name, Gate.new(:percentage_of_actors, ratio), true)

  # ---- disable ----

  @spec disable(atom, keyword) :: {:ok, boolean} | {:error, term}
  def disable(flag_name, options \\ [])

  def disable(flag_name, options) when is_atom(flag_name) do
    Bandera.Telemetry.span([:disable], %{flag_name: flag_name, options: options}, fn ->
      result = do_disable(flag_name, options)
      {result, %{result: result}}
    end)
  end

  defp do_disable(flag_name, []) when is_atom(flag_name),
    do: put_and_verify(flag_name, Gate.new(:boolean, false), [])

  defp do_disable(flag_name, for_actor: nil), do: do_disable(flag_name, [])

  defp do_disable(flag_name, for_actor: actor) when is_atom(flag_name),
    do: put_and_verify(flag_name, Gate.new(:actor, actor, false), for: actor)

  defp do_disable(flag_name, for_group: nil), do: do_disable(flag_name, [])

  defp do_disable(flag_name, for_group: group_name) when is_atom(flag_name),
    do: put_constant(flag_name, Gate.new(:group, group_name, false), false)

  defp do_disable(flag_name, for_percentage_of: {type, ratio})
       when is_atom(flag_name) and is_float(ratio) do
    case do_enable(flag_name, for_percentage_of: {type, 1.0 - ratio}) do
      {:ok, true} -> {:ok, false}
      error -> error
    end
  end

  # ---- clear ----

  @spec clear(atom, keyword) :: :ok | {:error, term}
  def clear(flag_name, options \\ [])

  def clear(flag_name, options) when is_atom(flag_name) do
    Bandera.Telemetry.span([:clear], %{flag_name: flag_name, options: options}, fn ->
      result = do_clear(flag_name, options)
      {result, %{result: result}}
    end)
  end

  defp do_clear(flag_name, []) when is_atom(flag_name) do
    case Store.active().delete(flag_name) do
      {:ok, _flag} -> :ok
      error -> error
    end
  end

  defp do_clear(flag_name, boolean: true), do: clear_gate(flag_name, Gate.new(:boolean, false))
  defp do_clear(flag_name, for_actor: nil), do: do_clear(flag_name, [])

  defp do_clear(flag_name, for_actor: actor) when is_atom(flag_name),
    do: clear_gate(flag_name, Gate.new(:actor, actor, false))

  defp do_clear(flag_name, for_group: nil), do: do_clear(flag_name, [])

  defp do_clear(flag_name, for_group: group_name) when is_atom(flag_name),
    do: clear_gate(flag_name, Gate.new(:group, group_name, false))

  defp do_clear(flag_name, for_percentage: true),
    do: clear_gate(flag_name, Gate.new(:percentage_of_time, 0.5))

  # ---- introspection ----

  @spec all_flag_names() :: {:ok, [atom]} | {:error, term}
  def all_flag_names, do: Store.active().all_flag_names()

  @spec all_flags() :: {:ok, [Flag.t()]} | {:error, term}
  def all_flags, do: Store.active().all_flags()

  @spec get_flag(atom) :: {:ok, Flag.t()} | {:error, term}
  def get_flag(flag_name) when is_atom(flag_name), do: Store.active().lookup(flag_name)

  # ---- helpers ----

  defp put_and_verify(flag_name, gate, verify_opts) do
    case Store.active().put(flag_name, gate) do
      {:ok, flag} -> {:ok, Flag.enabled?(flag, verify_opts)}
      error -> error
    end
  end

  defp put_constant(flag_name, gate, result) do
    case Store.active().put(flag_name, gate) do
      {:ok, _flag} -> {:ok, result}
      error -> error
    end
  end

  defp clear_gate(flag_name, gate) do
    case Store.active().delete(flag_name, gate) do
      {:ok, _flag} -> :ok
      error -> error
    end
  end

  defp lookup_failed(flag_name, error) do
    Logger.warning("[Bandera] store lookup for #{inspect(flag_name)} failed: #{inspect(error)}")
    false
  end
end
