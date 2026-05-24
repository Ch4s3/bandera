defmodule Bandera.Flag do
  @moduledoc "A named feature flag (a collection of gates) and its evaluation."

  alias Bandera.Gate

  defstruct name: nil, gates: []

  @type t :: %__MODULE__{name: atom, gates: [Gate.t()]}

  @doc """
  Builds a flag named `name` from a (possibly empty) list of gates.

  ## Examples

      iex> Bandera.Flag.new(:my_flag)
      %Bandera.Flag{name: :my_flag, gates: []}

      iex> flag = Bandera.Flag.new(:my_flag, [Bandera.Gate.new(:boolean, true)])
      iex> flag.gates
      [%Bandera.Gate{type: :boolean, for: nil, enabled: true}]
  """
  @spec new(atom, [Gate.t()]) :: t
  def new(name, gates \\ []) when is_atom(name) do
    %__MODULE__{name: name, gates: gates}
  end

  @doc """
  Evaluates the flag, returning whether it is enabled for the given input.

  With no `:for`, boolean, schedule, and percentage-of-time gates are consulted.
  With `for: item`, actor gates are checked first, then group gates, then rule,
  boolean, schedule, and percentage-of-actors gates. A flag with no gates is
  disabled.

  ## Examples

      iex> Bandera.Flag.enabled?(Bandera.Flag.new(:f, [Bandera.Gate.new(:boolean, true)]))
      true

      iex> Bandera.Flag.enabled?(Bandera.Flag.new(:f))
      false

      iex> Bandera.Flag.enabled?(Bandera.Flag.new(:f, [Bandera.Gate.new(:actor, "u1", true)]), for: "u1")
      true
  """
  @spec enabled?(t, keyword) :: boolean
  def enabled?(flag, options \\ [])

  def enabled?(%__MODULE__{gates: []}, _options), do: false

  def enabled?(%__MODULE__{gates: gates, name: name}, options) do
    item = Keyword.get(options, :for)
    context = Keyword.get(options, :context, %{})

    cond do
      item != nil -> evaluate(gates, name, item, context)
      # An explicit empty context is treated the same as no context (rule gates
      # are skipped) — enabled?(:f) and enabled?(:f, context: %{}) are equivalent.
      context != %{} -> check_rule_gates(gates, context) || base(gates)
      true -> base(gates)
    end
  end

  defp evaluate(gates, name, item, context) do
    case check_actor_gates(gates, item) do
      {:ok, result} ->
        result

      :ignore ->
        case check_group_gates(gates, item) do
          {:ok, result} ->
            result

          :ignore ->
            # actor path precedence: rule -> boolean -> schedule -> percentage. Percentage is
            # resolved only via check_percentage_gate/3 (which prefers
            # percentage_of_actors and falls back to percentage_of_time), so a
            # percentage_of_time gate is evaluated at most once — folding base/1 in
            # here would draw its random outcome twice and inflate its probability.
            check_rule_gates(gates, context) || check_boolean_gate(gates) ||
              check_schedule_gates(gates) || check_percentage_gate(gates, item, name)
        end
    end
  end

  defp base(gates),
    do:
      check_boolean_gate(gates) || check_schedule_gates(gates) ||
        check_percentage_of_time_gate(gates)

  defp check_rule_gates(gates, context) do
    gates
    |> Enum.filter(&Gate.rule?/1)
    |> Enum.any?(fn %Gate{value: constraints, enabled: enabled} ->
      # A rule with no constraints must not match (Enum.all?([]) is vacuously true),
      # so it can never grant to everyone.
      enabled and constraints != [] and
        Enum.all?(constraints, &Bandera.Constraint.match?(&1, context))
    end)
  end

  defp check_actor_gates(gates, item) do
    gates
    |> Enum.filter(&Gate.actor?/1)
    |> Enum.reduce_while(:ignore, fn gate, _acc ->
      case Gate.enabled?(gate, for: item) do
        :ignore -> {:cont, :ignore}
        {:ok, _} = result -> {:halt, result}
      end
    end)
  end

  defp check_group_gates(gates, item) do
    gates
    |> Enum.filter(&Gate.group?/1)
    |> Enum.reduce(:ignore, fn gate, acc ->
      case Gate.enabled?(gate, for: item) do
        :ignore -> acc
        {:ok, true} -> {:ok, true}
        {:ok, false} -> if acc == {:ok, true}, do: acc, else: {:ok, false}
      end
    end)
  end

  defp check_percentage_gate(gates, item, flag_name) do
    case Enum.find(gates, &Gate.percentage_of_actors?/1) do
      nil ->
        check_percentage_of_time_gate(gates)

      gate ->
        {:ok, enabled} = Gate.enabled?(gate, for: item, flag_name: flag_name)
        enabled
    end
  end

  @doc """
  Returns the variant chosen for the actor, or `options[:default]` (nil if not given).

  Requires a variant gate to exist on the flag and `:for` to be a non-nil actor.
  Passing `for: nil` or omitting `:for` also returns `default`. The bucket is
  stable per actor+flag using the SHA-256 score from `Bandera.Gate.score/2`.

  ## Examples

      iex> flag = Bandera.Flag.new(:f, [Bandera.Gate.new(:variant, %{"a" => 1, "b" => 1})])
      iex> v = Bandera.Flag.variant(flag, for: %{id: 1})
      iex> v in ["a", "b"]
      true
  """
  @spec variant(t, keyword) :: term
  def variant(%__MODULE__{gates: gates, name: name}, options \\ []) do
    default = Keyword.get(options, :default)

    with %Gate{value: weights} <- Enum.find(gates, &Gate.variant?/1),
         {:ok, actor} when not is_nil(actor) <- Keyword.fetch(options, :for) do
      allocate(weights, Gate.score(actor, name))
    else
      _ -> default
    end
  end

  defp allocate(weights, score) do
    total = weights |> Map.values() |> Enum.sum()
    pick = score * total
    sorted = Enum.sort_by(weights, fn {name, _w} -> name end)

    Enum.reduce_while(sorted, {0.0, nil}, fn {name, weight}, {acc, _last} ->
      acc = acc + weight
      if pick < acc, do: {:halt, {acc, name}}, else: {:cont, {acc, name}}
    end)
    |> elem(1)
  end

  defp check_schedule_gates(gates) do
    gates
    |> Enum.filter(&Gate.schedule?/1)
    |> Enum.any?(fn gate -> match?({:ok, true}, Gate.enabled?(gate)) end)
  end

  defp check_boolean_gate(gates) do
    case Enum.find(gates, &Gate.boolean?/1) do
      nil ->
        false

      gate ->
        {:ok, enabled} = Gate.enabled?(gate)
        enabled
    end
  end

  defp check_percentage_of_time_gate(gates) do
    case Enum.find(gates, &Gate.percentage_of_time?/1) do
      nil ->
        false

      gate ->
        {:ok, enabled} = Gate.enabled?(gate)
        enabled
    end
  end
end
