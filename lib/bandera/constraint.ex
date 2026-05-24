defmodule Bandera.Constraint do
  @moduledoc """
  A single targeting predicate evaluated against an evaluation context.

  Context values often arrive as strings (JSON bodies, query params, headers), so
  equality, membership, and ordering operators coerce numeric strings to numbers
  before comparing — `%{"age" => "20"}` **does** satisfy `{"age", :gte, 18}` because
  `"20"` coerces to `20`. Ordering between a number and a non-numeric string fails
  closed (no match). A missing attribute never matches. `:matches` is an unanchored
  regex, so `{"role", :matches, "admin"}` also matches `"superadmin"`; anchor with
  `^`/`$` if you need a full-string match.
  """

  @enforce_keys [:attribute, :operator, :values]
  defstruct [:attribute, :operator, :values]

  @operators [:eq, :neq, :in, :not_in, :contains, :gt, :gte, :lt, :lte, :matches]

  @type t :: %__MODULE__{attribute: String.t(), operator: atom, values: [term]}

  @doc """
  Builds a constraint for `attribute` using `operator` and `value`.

  `operator` must be one of `:eq`, `:neq`, `:in`, `:not_in`, `:contains`, `:gt`,
  `:gte`, `:lt`, `:lte`, or `:matches`. For list operators (`:in`, `:not_in`) pass a
  list as `value`; for all others a single scalar. Scalars are wrapped in a list
  internally.

  ## Examples

      iex> c = Bandera.Constraint.new("plan", :eq, "premium")
      iex> Bandera.Constraint.match?(c, %{"plan" => "premium"})
      true
  """
  @spec new(String.t(), atom, term) :: t
  def new(attribute, operator, values)
      when is_binary(attribute) and operator in @operators do
    %__MODULE__{attribute: attribute, operator: operator, values: List.wrap(values)}
  end

  @doc """
  Returns `true` when the constraint matches the given evaluation `context` map.

  The context map uses string keys. A missing key never matches. Numeric strings
  are coerced to numbers before comparison (see the module doc).

  ## Examples

      iex> c = Bandera.Constraint.new("age", :gte, 18)
      iex> Bandera.Constraint.match?(c, %{"age" => "20"})
      true

      iex> Bandera.Constraint.match?(c, %{"age" => "15"})
      false

      iex> Bandera.Constraint.match?(c, %{})
      false
  """
  @spec match?(t, map) :: boolean
  def match?(%__MODULE__{attribute: a, operator: op, values: values}, context) do
    apply_op(op, Map.get(context, a), values)
  end

  defp apply_op(_op, nil, _values), do: false
  defp apply_op(:eq, actual, [v]), do: coerce(actual) == coerce(v)
  defp apply_op(:neq, actual, [v]), do: coerce(actual) != coerce(v)
  defp apply_op(:in, actual, values), do: coerce(actual) in Enum.map(values, &coerce/1)
  defp apply_op(:not_in, actual, values), do: coerce(actual) not in Enum.map(values, &coerce/1)

  defp apply_op(:contains, actual, [v]) when is_binary(actual) and is_binary(v),
    do: String.contains?(actual, v)

  defp apply_op(:gt, actual, [v]), do: compare(actual, v) == :gt
  defp apply_op(:gte, actual, [v]), do: compare(actual, v) in [:gt, :eq]
  defp apply_op(:lt, actual, [v]), do: compare(actual, v) == :lt
  defp apply_op(:lte, actual, [v]), do: compare(actual, v) in [:lt, :eq]

  defp apply_op(:matches, actual, [pattern]) when is_binary(actual) and is_binary(pattern) do
    case compiled_regex(pattern) do
      {:ok, regex} -> Regex.match?(regex, actual)
      :error -> false
    end
  end

  defp apply_op(_op, _actual, _values), do: false

  # Numeric-aware ordering: compare as numbers when both sides are (or parse as)
  # numbers, as strings when both are strings, and report :incomparable for a
  # number/string mix so the caller fails closed.
  defp compare(a, b), do: do_compare(coerce(a), coerce(b))

  defp do_compare(a, b) when is_number(a) and is_number(b) and a > b, do: :gt
  defp do_compare(a, b) when is_number(a) and is_number(b) and a < b, do: :lt
  defp do_compare(a, b) when is_number(a) and is_number(b), do: :eq
  defp do_compare(a, b) when is_binary(a) and is_binary(b) and a > b, do: :gt
  defp do_compare(a, b) when is_binary(a) and is_binary(b) and a < b, do: :lt
  defp do_compare(a, b) when is_binary(a) and is_binary(b), do: :eq
  defp do_compare(_a, _b), do: :incomparable

  # A binary that parses cleanly (no leftover) as a number becomes that number;
  # everything else is returned unchanged.
  defp coerce(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} ->
        int

      _ ->
        case Float.parse(value) do
          {float, ""} -> float
          _ -> value
        end
    end
  end

  defp coerce(value), do: value

  # Compile each pattern once and memoize it in :persistent_term (patterns come from
  # developer-defined rules, so the key set is bounded). Failures are cached too, so a
  # bad pattern is never recompiled. Avoids recompiling on every evaluation.
  defp compiled_regex(pattern) do
    key = {__MODULE__, :regex, pattern}

    case :persistent_term.get(key, :unset) do
      :unset ->
        compiled =
          case Regex.compile(pattern) do
            {:ok, regex} -> {:ok, regex}
            {:error, _reason} -> :error
          end

        :persistent_term.put(key, compiled)
        compiled

      cached ->
        cached
    end
  end

  @doc false
  @spec to_map(t) :: map
  def to_map(%__MODULE__{attribute: a, operator: op, values: v}),
    do: %{"attribute" => a, "operator" => Atom.to_string(op), "values" => v}

  @doc false
  @spec from_map(map) :: t
  def from_map(%{"attribute" => a, "operator" => op, "values" => v}),
    do: new(a, String.to_existing_atom(op), v)
end
