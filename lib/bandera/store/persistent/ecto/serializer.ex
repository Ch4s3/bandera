defmodule Bandera.Store.Persistent.Ecto.Serializer do
  @moduledoc """
  Pure mapping between `Bandera.Gate`s and SQL table rows.

  A row is a plain map `%{flag_name, gate_type, target, enabled}`. Both percentage
  gate types collapse to `gate_type: "percentage"` (one percentage gate per flag),
  with the ratio and kind encoded in `target` (`"time/<r>"` / `"actors/<r>"`). The
  boolean gate's nil target is stored as the `"_bandera_none"` sentinel because SQL
  unique indexes treat NULL values as distinct.
  """

  alias Bandera.Flag
  alias Bandera.Gate

  @none "_bandera_none"

  @type row :: %{
          flag_name: String.t(),
          gate_type: String.t(),
          target: String.t(),
          enabled: boolean
        }

  @spec to_row(atom, Gate.t()) :: row
  def to_row(flag_name, %Gate{} = gate) do
    {gate_type, target} = type_and_target(gate)

    %{
      flag_name: to_string(flag_name),
      gate_type: gate_type,
      target: target,
      enabled: gate.enabled
    }
  end

  @spec serialize_target(term) :: String.t()
  def serialize_target(nil), do: @none
  def serialize_target(value) when is_binary(value), do: value
  def serialize_target(value), do: to_string(value)

  @spec deserialize_flag(atom, [map]) :: Flag.t()
  def deserialize_flag(flag_name, rows) when is_list(rows) do
    gates =
      rows
      |> Enum.sort_by(&{&1.gate_type, &1.target})
      |> Enum.map(&to_gate/1)

    Flag.new(to_atom(flag_name), gates)
  end

  defp type_and_target(%Gate{type: :percentage_of_time, for: ratio}),
    do: {"percentage", "time/#{ratio}"}

  defp type_and_target(%Gate{type: :percentage_of_actors, for: ratio}),
    do: {"percentage", "actors/#{ratio}"}

  defp type_and_target(%Gate{type: :boolean}), do: {"boolean", @none}

  defp type_and_target(%Gate{type: type, for: target}),
    do: {to_string(type), serialize_target(target)}

  defp to_gate(%{gate_type: "boolean", enabled: enabled}),
    do: %Gate{type: :boolean, for: nil, enabled: enabled}

  defp to_gate(%{gate_type: "actor", target: target, enabled: enabled}),
    do: %Gate{type: :actor, for: target, enabled: enabled}

  defp to_gate(%{gate_type: "group", target: target, enabled: enabled}),
    do: %Gate{type: :group, for: target, enabled: enabled}

  defp to_gate(%{gate_type: "percentage", target: "time/" <> ratio}),
    do: %Gate{type: :percentage_of_time, for: String.to_float(ratio), enabled: true}

  defp to_gate(%{gate_type: "percentage", target: "actors/" <> ratio}),
    do: %Gate{type: :percentage_of_actors, for: String.to_float(ratio), enabled: true}

  defp to_atom(name) when is_atom(name), do: name
  defp to_atom(name) when is_binary(name), do: String.to_atom(name)
end
