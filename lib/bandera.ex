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

  @doc """
  Returns whether `flag_name` is enabled.

  Pass `for: actor` to evaluate actor, group, and percentage-of-actors gates against
  a specific subject (the actor is identified via the `Bandera.Actor`/`Bandera.Group`
  protocols). The flag is read through the active store (cache included). A missing
  flag, or a store lookup error, resolves to `false` (the error is logged).

  ## Examples

      iex> Bandera.enabled?(:unknown_flag)
      false

      iex> Bandera.enable(:checkout)
      iex> Bandera.enabled?(:checkout)
      true

      iex> Bandera.enable(:beta, for_actor: "user-1")
      iex> Bandera.enabled?(:beta, for: "user-1")
      true
      iex> Bandera.enabled?(:beta, for: "user-2")
      false
  """
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

  @doc """
  Enables `flag_name`, optionally scoped by an option, and returns `{:ok, enabled?}`.

  With no options the boolean gate is turned on. Supported scopes:

    * `for_actor: actor` — enable for one actor
    * `for_group: group` — enable for a named group
    * `for_percentage_of: {:time, ratio}` — enable for a ratio of calls
    * `for_percentage_of: {:actors, ratio}` — enable for a ratio of actors

  `ratio` is a float in `0.0 < r < 1.0`. The write goes to the persistent store and
  busts/refreshes the cache; returns `{:error, reason}` if the store write fails.

  ## Examples

      iex> Bandera.enable(:checkout)
      {:ok, true}

      iex> Bandera.enable(:beta, for_actor: "user-1")
      {:ok, true}

      iex> Bandera.enable(:gradual, for_percentage_of: {:actors, 0.25})
      {:ok, true}
  """
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

  @doc """
  Disables `flag_name`, optionally scoped by an option, and returns `{:ok, enabled?}`.

  Accepts the same scopes as `enable/2` (`for_actor:`, `for_group:`,
  `for_percentage_of:`). For a percentage scope, disabling for `ratio` is equivalent
  to enabling for `1.0 - ratio`. Returns `{:error, reason}` on a store write failure.

  ## Examples

      iex> Bandera.disable(:checkout)
      {:ok, false}

      iex> Bandera.enable(:beta)
      iex> Bandera.disable(:beta)
      {:ok, false}
  """
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

  @doc """
  Removes gates from `flag_name`, returning `:ok`.

  With no options the whole flag (all its gates) is deleted. A scope removes just
  that gate, letting evaluation fall through to whatever remains:

    * `boolean: true` — clear the boolean gate
    * `for_actor: actor` — clear one actor gate
    * `for_group: group` — clear one group gate
    * `for_percentage: true` — clear the percentage gate

  Returns `{:error, reason}` if the store delete fails.

  ## Examples

      iex> Bandera.enable(:checkout)
      iex> Bandera.clear(:checkout)
      :ok
      iex> Bandera.enabled?(:checkout)
      false
  """
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

  @doc """
  Returns `{:ok, names}` with every known flag name, or `{:error, reason}`.

  ## Examples

      iex> Bandera.enable(:checkout)
      iex> Bandera.all_flag_names()
      {:ok, [:checkout]}
  """
  @spec all_flag_names() :: {:ok, [atom]} | {:error, term}
  def all_flag_names, do: Store.active().all_flag_names()

  @doc """
  Returns `{:ok, flags}` with every stored `Bandera.Flag`, or `{:error, reason}`.

  ## Examples

      iex> Bandera.enable(:checkout)
      iex> {:ok, flags} = Bandera.all_flags()
      iex> Enum.map(flags, & &1.name)
      [:checkout]
  """
  @spec all_flags() :: {:ok, [Flag.t()]} | {:error, term}
  def all_flags, do: Store.active().all_flags()

  @doc """
  Looks up a single flag, returning `{:ok, %Bandera.Flag{}}` or `{:error, reason}`.

  An unknown flag still returns `{:ok, flag}` with an empty gate list (a disabled
  flag), not an error.

  ## Examples

      iex> Bandera.enable(:checkout)
      iex> {:ok, flag} = Bandera.get_flag(:checkout)
      iex> flag.gates
      [%Bandera.Gate{type: :boolean, for: nil, enabled: true}]

      iex> {:ok, flag} = Bandera.get_flag(:unknown_flag)
      iex> flag.gates
      []
  """
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
