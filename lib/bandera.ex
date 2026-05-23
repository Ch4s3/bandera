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

  Pass `default: true` to fail open (return true) when the store is unreachable; the
  default is false.

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

  def enabled?(flag_name, options) when is_atom(flag_name) do
    {default, rest} = Keyword.pop(options, :default, false)
    eval_opts = rest |> Keyword.take([:for, :context]) |> drop_nil_for()

    result =
      case Store.active().lookup(flag_name) do
        {:ok, flag} ->
          if prerequisites_met?(flag, eval_opts, [flag_name]) do
            Flag.enabled?(expand_segments(flag), eval_opts)
          else
            false
          end

        error ->
          lookup_failed(flag_name, error, default)
      end

    track_enabled?(flag_name, eval_opts, result)
  end

  defp drop_nil_for(opts) do
    case Keyword.fetch(opts, :for) do
      {:ok, nil} -> Keyword.delete(opts, :for)
      _ -> opts
    end
  end

  @segment_prefix "bandera_segment:"

  # Expand each :segment gate into the referenced segment's :rule gate so the pure
  # Flag evaluator can resolve it. Unresolvable segments are dropped (ignored).
  defp expand_segments(%Flag{gates: gates} = flag) do
    expanded =
      Enum.flat_map(gates, fn
        %Gate{type: :segment, for: name, enabled: enabled} ->
          case Store.active().lookup(String.to_atom(@segment_prefix <> name)) do
            {:ok, %Flag{gates: seg_gates}} ->
              case Enum.find(seg_gates, &Gate.rule?/1) do
                %Gate{value: constraints} -> [Gate.new(:rule, constraints, enabled)]
                _ -> []
              end

            _ ->
              []
          end

        gate ->
          [gate]
      end)

    %{flag | gates: expanded}
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
    * `when: constraints` — enable when the evaluation context matches a rule
    * `for_segment: name` — enable for a reusable named segment
    * `requires: parent` (or `{parent, required_state}`) — add a prerequisite
    * `schedule: {from, until}` — enable inside an ISO-8601 time window

  `ratio` is a float in `0.0 < r < 1.0`. The write goes to the persistent store and
  busts/refreshes the cache; returns `{:error, reason}` if the store write fails.

  The returned `enabled?` is the immediate state for unconditional/percentage gates.
  For the **conditional** scopes (`when:`, `for_segment:`, `requires:`, `schedule:`)
  it is `true` to signal a successful write — those gates are evaluated per call by
  `enabled?/2` against the relevant context, actor, time, or parent flag.

  Pass `by: identity` to record who made the change; it is carried in the write
  telemetry metadata (see `Bandera.Audit`) and does not affect the gate written.

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
    {_by, rest} = Keyword.pop(options, :by)

    Bandera.Telemetry.span([:enable], %{flag_name: flag_name, options: options}, fn ->
      result = do_enable(flag_name, rest)
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

  defp do_enable(_flag_name, when: []),
    do: raise(ArgumentError, "enable/2 :when requires at least one constraint")

  defp do_enable(flag_name, when: constraints) when is_atom(flag_name) and is_list(constraints) do
    gate = Gate.new(:rule, Enum.map(constraints, &to_constraint/1), true)
    put_constant(flag_name, gate, true)
  end

  defp do_enable(flag_name, for_segment: name) when is_atom(flag_name),
    do: put_constant(flag_name, Gate.new(:segment, name, true), true)

  defp do_enable(flag_name, schedule: {from, until}) when is_atom(flag_name),
    do: put_constant(flag_name, Gate.new(:schedule, {from, until}), true)

  defp do_enable(flag_name, requires: parent) when is_atom(flag_name) and is_atom(parent),
    do: put_constant(flag_name, Gate.new(:prerequisite, parent, true), true)

  defp do_enable(flag_name, requires: {parent, required})
       when is_atom(flag_name) and is_atom(parent) and is_boolean(required),
       do: put_constant(flag_name, Gate.new(:prerequisite, parent, required), true)

  defp to_constraint(%Bandera.Constraint{} = c), do: c

  defp to_constraint({attribute, operator, value}),
    do: Bandera.Constraint.new(attribute, operator, value)

  # ---- disable ----

  @doc """
  Disables `flag_name`, optionally scoped by an option, and returns `{:ok, enabled?}`.

  Accepts the same scopes as `enable/2` (`for_actor:`, `for_group:`,
  `for_percentage_of:`). For a percentage scope, disabling for `ratio` is equivalent
  to enabling for `1.0 - ratio`. Returns `{:error, reason}` on a store write failure.

  Accepts `by: identity` to record who made the change (see `Bandera.Audit`).

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
    {_by, rest} = Keyword.pop(options, :by)

    Bandera.Telemetry.span([:disable], %{flag_name: flag_name, options: options}, fn ->
      result = do_disable(flag_name, rest)
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

  Accepts `by: identity` to record who made the change (see `Bandera.Audit`).

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
    {_by, rest} = Keyword.pop(options, :by)

    Bandera.Telemetry.span([:clear], %{flag_name: flag_name, options: options}, fn ->
      result = do_clear(flag_name, rest)
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

  # ---- variant ----

  @doc """
  Returns the variant chosen for the flag named `flag_name` (bucketed by the actor
  passed via `for:`), or `options[:default]` (nil if not given) when the flag is
  missing or has no variant gate.

  Looks up the flag from the active store and delegates to `Flag.variant/2`. A missing
  flag or store lookup error returns `options[:default]` (the error is logged).

  ## Examples

      iex> Bandera.put_variants(:ab_test, %{"a" => 1, "b" => 1})
      iex> Bandera.variant(:ab_test, for: %{id: 1}) in ["a", "b"]
      true
  """
  @spec variant(atom, keyword) :: term
  def variant(flag_name, options \\ []) when is_atom(flag_name) do
    default = Keyword.get(options, :default)

    result =
      case Store.active().lookup(flag_name) do
        {:ok, flag} -> Flag.variant(flag, options)
        error -> variant_lookup_failed(flag_name, error, default)
      end

    Bandera.Telemetry.event([:variant], %{flag_name: flag_name, options: options, result: result})
    result
  end

  @doc """
  Stores a `:variant` gate for `flag_name` with the given `weights` map.

  `weights` is a `%{variant_name => weight}` map; actors are bucketed proportionally
  by weight using a stable SHA-256 hash per actor+flag. Returns `{:ok, flag}` on
  success, `{:error, reason}` on a store write failure.

  ## Examples

      iex> {:ok, flag} = Bandera.put_variants(:hero, %{"blue" => 1, "green" => 1})
      iex> flag.name
      :hero
  """
  @spec put_variants(atom, %{optional(String.t()) => number}, keyword) ::
          {:ok, Flag.t()} | {:error, term}
  def put_variants(flag_name, weights, _options \\ [])
      when is_atom(flag_name) and is_map(weights) do
    Bandera.Telemetry.span([:put_variants], %{flag_name: flag_name, weights: weights}, fn ->
      result = Store.active().put(flag_name, Gate.new(:variant, weights))
      {result, %{result: result}}
    end)
  end

  defp variant_lookup_failed(flag_name, error, default) do
    Logger.warning("[Bandera] variant lookup for #{inspect(flag_name)} failed: #{inspect(error)}")
    default
  end

  # ---- segments ----

  @doc """
  Stores a reusable named constraint set (a segment) under the reserved key
  `:"bandera_segment:<name>"`.

  Segments are referenced from flags via `enable(flag, for_segment: name)` and are
  expanded at evaluation time so that `Flag` stays pure. `name` must be a
  developer-defined atom — never untrusted user input.

  ## Examples

      iex> {:ok, _} = Bandera.put_segment(:premium, [{"plan", :eq, "premium"}])
      iex> {:ok, _flag} = Bandera.get_flag(:"bandera_segment:premium")
  """
  @spec put_segment(atom, [tuple | Bandera.Constraint.t()]) :: {:ok, Flag.t()} | {:error, term}
  def put_segment(_name, []),
    do: raise(ArgumentError, "put_segment/2 requires at least one constraint")

  def put_segment(name, constraints) when is_atom(name) and is_list(constraints) do
    gate = Gate.new(:rule, Enum.map(constraints, &to_constraint/1), true)
    Store.active().put(segment_key(name), gate)
  end

  defp segment_key(name), do: String.to_atom(@segment_prefix <> to_string(name))

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

  @doc """
  List flags whose last evaluation is older than `older_than` days (or never
  evaluated). Requires `Bandera.Usage` to be running and attached.
  """
  @spec stale_flags(keyword) :: [atom]
  def stale_flags(opts \\ []) do
    # Clamp to >= 0 so a negative window can't push the cutoff into the future (which
    # would report every flag, even freshly-evaluated ones, as stale).
    days = opts |> Keyword.get(:older_than, 30) |> max(0)
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    case all_flag_names() do
      {:ok, names} ->
        names
        |> Enum.reject(&segment_flag?/1)
        |> Enum.filter(fn name ->
          case safe_last_evaluated(name) do
            nil -> true
            at -> DateTime.compare(at, cutoff) == :lt
          end
        end)

      _ ->
        []
    end
  end

  # Internal segment definitions are stored as reserved flags and are never
  # evaluated via enabled?/2, so they would always look stale — exclude them.
  defp segment_flag?(name), do: String.starts_with?(to_string(name), @segment_prefix)

  # Calls Usage.last_evaluated but returns nil when the Usage table isn't running.
  defp safe_last_evaluated(flag_name) do
    Bandera.Usage.last_evaluated(flag_name)
  rescue
    ArgumentError -> nil
  end

  defp prerequisites_met?(flag, eval_opts, visited) do
    {status, _memo} = prereqs_status(flag, eval_opts, visited, %{})
    status == :ok
  end

  # Status of a flag's prerequisite gates: :ok (all met), :not_met (a parent is in the
  # wrong state), or :cycle (resolving a parent re-entered a flag already on the stack).
  # A cycle propagates as :cycle so it fails closed uniformly — including required:false
  # edges, which a plain false would otherwise satisfy.
  defp prereqs_status(%Flag{gates: gates}, eval_opts, visited, memo) do
    gates
    |> Enum.filter(&Gate.prerequisite?/1)
    |> Enum.reduce_while({:ok, memo}, fn %Gate{for: parent, enabled: required}, {_status, m} ->
      cond do
        # An unresolved parent (e.g. an unknown atom from corrupt store data) fails closed.
        not is_atom(parent) ->
          {:halt, {:not_met, m}}

        true ->
          case resolve(parent, eval_opts, visited, m) do
            {{:ok, enabled}, m} when enabled == required -> {:cont, {:ok, m}}
            {{:ok, _enabled}, m} -> {:halt, {:not_met, m}}
            {:cycle, m} -> {:halt, {:cycle, m}}
          end
      end
    end)
  end

  # Resolve a flag's effective enabled state, carrying a per-evaluation memo (so a
  # shared/diamond prerequisite is evaluated once, not re-walked exponentially) and a
  # visited set for cycle detection. Returns `{{:ok, boolean} | :cycle, memo}`. Cycle
  # results are never memoized so they stay path-correct.
  defp resolve(flag_name, eval_opts, visited, memo) do
    cond do
      flag_name in visited ->
        {:cycle, memo}

      Map.has_key?(memo, flag_name) ->
        {{:ok, Map.fetch!(memo, flag_name)}, memo}

      true ->
        case Store.active().lookup(flag_name) do
          {:ok, flag} ->
            case prereqs_status(flag, eval_opts, [flag_name | visited], memo) do
              {:cycle, m} ->
                {:cycle, m}

              {:not_met, m} ->
                {{:ok, false}, Map.put(m, flag_name, false)}

              {:ok, m} ->
                enabled = Flag.enabled?(expand_segments(flag), eval_opts)
                {{:ok, enabled}, Map.put(m, flag_name, enabled)}
            end

          _ ->
            {{:ok, false}, Map.put(memo, flag_name, false)}
        end
    end
  end

  defp lookup_failed(flag_name, error, default) do
    Logger.warning("[Bandera] store lookup for #{inspect(flag_name)} failed: #{inspect(error)}")
    default
  end
end
