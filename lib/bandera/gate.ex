defmodule Bandera.Gate do
  @moduledoc "A single feature-flag gate and its evaluation."

  alias Bandera.Actor
  alias Bandera.Group

  defstruct [:type, :for, :enabled, :value]

  @type t :: %__MODULE__{
          type:
            :boolean
            | :actor
            | :group
            | :percentage_of_time
            | :percentage_of_actors
            | :variant
            | :rule
            | :segment
            | :prerequisite
            | :schedule,
          for: term,
          enabled: boolean,
          value: term
        }

  defmodule InvalidTargetError do
    @moduledoc "Raised when a percentage gate is built with a ratio outside `0.0 < r < 1.0`."
    defexception [:message]
  end

  @doc """
  Builds a gate of the given `type`.

  The two-argument form covers `:boolean` gates (with a boolean value), the two
  percentage gate types (`:percentage_of_time` / `:percentage_of_actors`, with a
  ratio strictly between `0.0` and `1.0`), and `:variant` gates (with a
  `%{name => weight}` map). The three-argument form (see below) covers `:actor`
  and `:group` gates.

  Raises `Bandera.Gate.InvalidTargetError` when a percentage ratio is out of range
  or a variant weights map is empty.

  ## Examples

      iex> Bandera.Gate.new(:boolean, true)
      %Bandera.Gate{type: :boolean, for: nil, enabled: true}

      iex> Bandera.Gate.new(:percentage_of_actors, 0.25)
      %Bandera.Gate{type: :percentage_of_actors, for: 0.25, enabled: true}

      iex> Bandera.Gate.new(:percentage_of_time, 1.5)
      ** (Bandera.Gate.InvalidTargetError) percentage_of_time gates require a ratio in the range 0.0 < r < 1.0
  """
  @spec new(:boolean, boolean) :: t
  def new(:boolean, enabled) when is_boolean(enabled) do
    %__MODULE__{type: :boolean, for: nil, enabled: enabled}
  end

  @spec new(:percentage_of_time | :percentage_of_actors, float) :: t
  def new(type, ratio)
      when type in [:percentage_of_time, :percentage_of_actors] and is_float(ratio) and
             ratio > 0.0 and ratio < 1.0 do
    %__MODULE__{type: type, for: ratio, enabled: true}
  end

  def new(type, _ratio) when type in [:percentage_of_time, :percentage_of_actors] do
    raise InvalidTargetError, "#{type} gates require a ratio in the range 0.0 < r < 1.0"
  end

  @spec new(:variant, %{optional(String.t()) => number}) :: t
  def new(:variant, weights) when is_map(weights) and map_size(weights) > 0 do
    values = Map.values(weights)

    cond do
      not Enum.all?(values, &(is_number(&1) and &1 >= 0)) ->
        raise InvalidTargetError, "variant weights must be non-negative numbers"

      not Enum.any?(values, &(&1 > 0)) ->
        raise InvalidTargetError, "variant gates require at least one positive weight"

      true ->
        %__MODULE__{type: :variant, for: nil, enabled: true, value: weights}
    end
  end

  def new(:variant, _weights) do
    raise InvalidTargetError, "variant gates require a non-empty %{name => weight} map"
  end

  @spec new(:schedule, {String.t() | nil, String.t() | nil}) :: t
  def new(:schedule, {from, until}) do
    %__MODULE__{
      type: :schedule,
      for: nil,
      enabled: true,
      value: %{"from" => from, "until" => until}
    }
  end

  @doc """
  Builds an `:actor` or `:group` gate targeting `for` with the boolean `enabled`.

  Actor targets are normalised to a string id via the `Bandera.Actor` protocol;
  group names are stringified.

  ## Examples

      iex> Bandera.Gate.new(:actor, "user-1", true)
      %Bandera.Gate{type: :actor, for: "user-1", enabled: true}

      iex> Bandera.Gate.new(:group, :beta, false)
      %Bandera.Gate{type: :group, for: "beta", enabled: false}
  """
  @spec new(:actor, term, boolean) :: t
  def new(:actor, actor, enabled) when is_boolean(enabled) do
    %__MODULE__{type: :actor, for: Actor.id(actor), enabled: enabled}
  end

  @spec new(:group, atom | String.t(), boolean) :: t
  def new(:group, group_name, enabled) when is_boolean(enabled) do
    %__MODULE__{type: :group, for: to_string(group_name), enabled: enabled}
  end

  @spec new(:rule, [Bandera.Constraint.t()], boolean) :: t
  def new(:rule, constraints, enabled) when is_list(constraints) and is_boolean(enabled) do
    %__MODULE__{type: :rule, for: nil, enabled: enabled, value: constraints}
  end

  @spec new(:segment, atom | String.t(), boolean) :: t
  def new(:segment, name, enabled) when is_boolean(enabled) do
    %__MODULE__{type: :segment, for: to_string(name), enabled: enabled}
  end

  @spec new(:prerequisite, atom, boolean) :: t
  def new(:prerequisite, other_flag, required)
      when is_atom(other_flag) and is_boolean(required) do
    %__MODULE__{type: :prerequisite, for: other_flag, enabled: required}
  end

  @doc """
  Returns `true` if the gate is a `:boolean` gate.

  ## Examples

      iex> Bandera.Gate.boolean?(Bandera.Gate.new(:boolean, true))
      true

      iex> Bandera.Gate.boolean?(Bandera.Gate.new(:actor, "u1", true))
      false
  """
  @spec boolean?(t) :: boolean
  def boolean?(%__MODULE__{type: :boolean}), do: true
  def boolean?(%__MODULE__{}), do: false

  @doc """
  Returns `true` if the gate is an `:actor` gate.

  ## Examples

      iex> Bandera.Gate.actor?(Bandera.Gate.new(:actor, "u1", true))
      true

      iex> Bandera.Gate.actor?(Bandera.Gate.new(:boolean, true))
      false
  """
  @spec actor?(t) :: boolean
  def actor?(%__MODULE__{type: :actor}), do: true
  def actor?(%__MODULE__{}), do: false

  @doc """
  Returns `true` if the gate is a `:group` gate.

  ## Examples

      iex> Bandera.Gate.group?(Bandera.Gate.new(:group, :beta, true))
      true

      iex> Bandera.Gate.group?(Bandera.Gate.new(:boolean, true))
      false
  """
  @spec group?(t) :: boolean
  def group?(%__MODULE__{type: :group}), do: true
  def group?(%__MODULE__{}), do: false

  @doc """
  Returns `true` if the gate is a `:percentage_of_time` gate.

  ## Examples

      iex> Bandera.Gate.percentage_of_time?(Bandera.Gate.new(:percentage_of_time, 0.5))
      true

      iex> Bandera.Gate.percentage_of_time?(Bandera.Gate.new(:percentage_of_actors, 0.5))
      false
  """
  @spec percentage_of_time?(t) :: boolean
  def percentage_of_time?(%__MODULE__{type: :percentage_of_time}), do: true
  def percentage_of_time?(%__MODULE__{}), do: false

  @doc """
  Returns `true` if the gate is a `:percentage_of_actors` gate.

  ## Examples

      iex> Bandera.Gate.percentage_of_actors?(Bandera.Gate.new(:percentage_of_actors, 0.5))
      true

      iex> Bandera.Gate.percentage_of_actors?(Bandera.Gate.new(:percentage_of_time, 0.5))
      false
  """
  @spec percentage_of_actors?(t) :: boolean
  def percentage_of_actors?(%__MODULE__{type: :percentage_of_actors}), do: true
  def percentage_of_actors?(%__MODULE__{}), do: false

  @doc """
  Returns `true` if the gate is a `:variant` gate.

  ## Examples

      iex> Bandera.Gate.variant?(Bandera.Gate.new(:variant, %{"a" => 1}))
      true

      iex> Bandera.Gate.variant?(Bandera.Gate.new(:boolean, true))
      false
  """
  @spec variant?(t) :: boolean
  def variant?(%__MODULE__{type: :variant}), do: true
  def variant?(%__MODULE__{}), do: false

  @doc """
  Returns `true` if the gate is a `:rule` gate.

  ## Examples

      iex> Bandera.Gate.rule?(Bandera.Gate.new(:rule, [], true))
      true

      iex> Bandera.Gate.rule?(Bandera.Gate.new(:boolean, true))
      false
  """
  @spec rule?(t) :: boolean
  def rule?(%__MODULE__{type: :rule}), do: true
  def rule?(%__MODULE__{}), do: false

  @doc """
  Returns `true` if the gate is a `:segment` gate.

  ## Examples

      iex> Bandera.Gate.segment?(Bandera.Gate.new(:segment, :premium, true))
      true

      iex> Bandera.Gate.segment?(Bandera.Gate.new(:boolean, true))
      false
  """
  @spec segment?(t) :: boolean
  def segment?(%__MODULE__{type: :segment}), do: true
  def segment?(%__MODULE__{}), do: false

  @doc """
  Returns `true` if the gate is a `:prerequisite` gate.
  """
  @spec prerequisite?(t) :: boolean
  def prerequisite?(%__MODULE__{type: :prerequisite}), do: true
  def prerequisite?(%__MODULE__{}), do: false

  @doc """
  Returns `true` if the gate is a `:schedule` gate.
  """
  @spec schedule?(t) :: boolean
  def schedule?(%__MODULE__{type: :schedule}), do: true
  def schedule?(%__MODULE__{}), do: false

  @doc """
  Returns the gate's storage id, used as the per-flag slot key.

  Both percentage gate types collapse to `"percentage"` (a flag holds at most one
  percentage gate), while actor and group ids embed their target.

  ## Examples

      iex> Bandera.Gate.id(Bandera.Gate.new(:boolean, true))
      "boolean"

      iex> Bandera.Gate.id(Bandera.Gate.new(:actor, "u1", true))
      "actor/u1"

      iex> Bandera.Gate.id(Bandera.Gate.new(:percentage_of_actors, 0.25))
      "percentage"
  """
  @spec id(t) :: String.t()
  def id(%__MODULE__{type: :boolean}), do: "boolean"
  def id(%__MODULE__{type: :actor, for: actor_id}), do: "actor/#{actor_id}"
  def id(%__MODULE__{type: :group, for: group}), do: "group/#{group}"
  def id(%__MODULE__{type: :percentage_of_time}), do: "percentage"
  def id(%__MODULE__{type: :percentage_of_actors}), do: "percentage"
  def id(%__MODULE__{type: :variant}), do: "variant"
  def id(%__MODULE__{type: :rule}), do: "rule"
  def id(%__MODULE__{type: :segment, for: name}), do: "segment/#{name}"
  def id(%__MODULE__{type: :prerequisite, for: f}), do: "prerequisite/#{f}"
  def id(%__MODULE__{type: :schedule}), do: "schedule"

  @doc """
  Evaluates a single gate against `options`.

  Returns `{:ok, boolean}` when this gate decides the outcome, or `:ignore` when it
  does not apply to the given input (so `Bandera.Flag` can fall through to the next
  gate). Boolean and percentage-of-time gates always decide; actor and group gates
  return `:ignore` unless `options[:for]` matches their target; percentage-of-actors
  gates require both `:for` and `:flag_name`.

  ## Examples

      iex> Bandera.Gate.enabled?(Bandera.Gate.new(:boolean, true))
      {:ok, true}

      iex> Bandera.Gate.enabled?(Bandera.Gate.new(:actor, "u1", true), for: "u1")
      {:ok, true}

      iex> Bandera.Gate.enabled?(Bandera.Gate.new(:actor, "u1", true), for: "u2")
      :ignore
  """
  @spec enabled?(t, keyword) :: {:ok, boolean} | :ignore
  def enabled?(gate, options \\ [])

  def enabled?(%__MODULE__{type: :schedule, value: %{"from" => from, "until" => until}}, _opts) do
    now = DateTime.utc_now()
    {:ok, after?(now, from) and before?(now, until)}
  end

  def enabled?(%__MODULE__{type: :boolean, enabled: enabled}, _options) do
    {:ok, enabled}
  end

  def enabled?(%__MODULE__{type: :actor, for: actor_id, enabled: enabled}, options) do
    case Keyword.fetch(options, :for) do
      {:ok, actor} -> if Actor.id(actor) == actor_id, do: {:ok, enabled}, else: :ignore
      :error -> :ignore
    end
  end

  def enabled?(%__MODULE__{type: :group, for: group, enabled: enabled}, options) do
    case Keyword.fetch(options, :for) do
      {:ok, item} -> if Group.in?(item, group), do: {:ok, enabled}, else: :ignore
      :error -> :ignore
    end
  end

  def enabled?(%__MODULE__{type: :percentage_of_time, for: ratio}, _options) do
    {:ok, :rand.uniform(10_000) / 10_000 <= ratio}
  end

  def enabled?(%__MODULE__{type: :percentage_of_actors, for: ratio}, options) do
    actor = Keyword.fetch!(options, :for)
    flag_name = Keyword.fetch!(options, :flag_name)
    {:ok, score(actor, flag_name) <= ratio}
  end

  @doc """
  Deterministic score in `[0.0, 1.0)` for an actor + flag pair (first 16 bits of
  SHA-256).

  The pairing of actor and flag name means an actor lands at a different point in
  every flag's rollout, and the result is stable across nodes and restarts — the
  basis for sticky `percentage_of_actors` gates.

  ## Examples

      iex> Bandera.Gate.score("user-42", :my_flag)
      0.9317474365234375

      iex> Bandera.Gate.score("user-42", :my_flag) == Bandera.Gate.score("user-42", :my_flag)
      true
  """
  @spec score(term, atom) :: float
  def score(actor, flag_name) do
    blob = Actor.id(actor) <> to_string(flag_name)
    <<score::size(16), _rest::binary>> = :crypto.hash(:sha256, blob)
    score / 65_536
  end

  # A nil bound is open-ended. A malformed stored bound fails closed (the window is
  # treated as not-yet-open / already-closed) rather than crashing every evaluation —
  # schedule values can come from hand-edited or corrupted store rows.
  defp after?(_now, nil), do: true

  defp after?(now, iso) do
    case parse(iso) do
      {:ok, at} -> DateTime.compare(now, at) != :lt
      :error -> false
    end
  end

  defp before?(_now, nil), do: true

  defp before?(now, iso) do
    case parse(iso) do
      {:ok, at} -> DateTime.compare(now, at) == :lt
      :error -> false
    end
  end

  defp parse(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, _reason} -> :error
    end
  end

  defp parse(_iso), do: :error
end
