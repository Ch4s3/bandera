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

  With no `:for`, only boolean and percentage-of-time gates are consulted. With
  `for: item`, actor gates are checked first, then group gates, then the boolean
  and percentage-of-actors gates. A flag with no gates is disabled.

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

  def enabled?(%__MODULE__{gates: gates}, []) do
    check_boolean_gate(gates) || check_percentage_of_time_gate(gates)
  end

  def enabled?(%__MODULE__{gates: gates, name: flag_name}, for: item) do
    case check_actor_gates(gates, item) do
      {:ok, result} ->
        result

      :ignore ->
        case check_group_gates(gates, item) do
          {:ok, result} -> result
          :ignore -> check_boolean_gate(gates) || check_percentage_gate(gates, item, flag_name)
        end
    end
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
