defmodule Bandera.Store.Persistent.Redis.Serializer do
  @moduledoc """
  Pure mapping between `Bandera.Gate`s and Redis hash `{field, value}` pairs.

  The hash field is the gate id (`Bandera.Gate.id/1`), so both percentage gate
  types share the `"percentage"` field (one percentage gate per flag — an HSET
  overwrites it). The value encodes `"true"`/`"false"` for boolean/actor/group, or
  `"time/<ratio>"`/`"actors/<ratio>"` for percentage gates.

  Flag names read back are converted to atoms via `String.to_atom/1` (supporting
  listing flags created in a prior VM session). Flag names must therefore be a
  bounded, developer-defined set — never untrusted user input.
  """

  alias Bandera.Flag
  alias Bandera.Gate

  @doc """
  Serializes a gate to the `{field, value}` pair stored in the flag's Redis hash.

  The field is the gate id (so the percentage slot is shared); the value encodes the
  ratio for percentage gates and the boolean otherwise.

  ## Examples

      iex> Bandera.Store.Persistent.Redis.Serializer.serialize(Bandera.Gate.new(:boolean, true))
      {"boolean", "true"}

      iex> Bandera.Store.Persistent.Redis.Serializer.serialize(Bandera.Gate.new(:actor, "u1", true))
      {"actor/u1", "true"}

      iex> Bandera.Store.Persistent.Redis.Serializer.serialize(Bandera.Gate.new(:percentage_of_time, 0.5))
      {"percentage", "time/0.5"}
  """
  @spec serialize(Gate.t()) :: {String.t(), String.t()}
  def serialize(%Gate{type: :percentage_of_time, for: ratio} = gate),
    do: {Gate.id(gate), "time/#{ratio}"}

  def serialize(%Gate{type: :percentage_of_actors, for: ratio} = gate),
    do: {Gate.id(gate), "actors/#{ratio}"}

  def serialize(%Gate{enabled: enabled} = gate), do: {Gate.id(gate), to_string(enabled)}

  @doc """
  Returns the Redis hash field for a gate (its id) — the hash key used to delete it.

  ## Examples

      iex> Bandera.Store.Persistent.Redis.Serializer.field(Bandera.Gate.new(:group, :beta, true))
      "group/beta"
  """
  @spec field(Gate.t()) :: String.t()
  def field(%Gate{} = gate), do: Gate.id(gate)

  @doc """
  Rebuilds a `Bandera.Flag` from a flat `HGETALL` reply (alternating field/value
  entries).

  The flag name is converted to an atom, so it must be a bounded, developer-defined
  value — never untrusted input.

  ## Examples

      iex> flag = Bandera.Store.Persistent.Redis.Serializer.deserialize_flag(:my_flag, ["boolean", "true"])
      iex> flag.name
      :my_flag
      iex> flag.gates
      [%Bandera.Gate{type: :boolean, for: nil, enabled: true}]
  """
  @spec deserialize_flag(atom | String.t(), [String.t()]) :: Flag.t()
  def deserialize_flag(flag_name, flat) when is_list(flat) do
    gates =
      flat
      |> Enum.chunk_every(2)
      |> Enum.map(&deserialize_pair/1)

    Flag.new(to_atom(flag_name), gates)
  end

  defp deserialize_pair(["boolean", value]),
    do: %Gate{type: :boolean, for: nil, enabled: parse_bool(value)}

  defp deserialize_pair(["actor/" <> actor_id, value]),
    do: %Gate{type: :actor, for: actor_id, enabled: parse_bool(value)}

  defp deserialize_pair(["group/" <> group, value]),
    do: %Gate{type: :group, for: group, enabled: parse_bool(value)}

  defp deserialize_pair(["percentage", "time/" <> ratio]),
    do: %Gate{type: :percentage_of_time, for: String.to_float(ratio), enabled: true}

  defp deserialize_pair(["percentage", "actors/" <> ratio]),
    do: %Gate{type: :percentage_of_actors, for: String.to_float(ratio), enabled: true}

  defp parse_bool("true"), do: true
  defp parse_bool(_), do: false

  defp to_atom(name) when is_atom(name), do: name
  defp to_atom(name) when is_binary(name), do: String.to_atom(name)
end
