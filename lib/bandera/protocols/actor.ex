defprotocol Bandera.Actor do
  @moduledoc """
  Identifies an actor (e.g. a user) for actor and percentage_of_actors gates.
  The id must be a binary and stable for a given actor across a flag's lifetime.

  Implementations ship for binaries, integers, and maps with an `:id` key; define
  the protocol for your own struct to control how it is identified.
  """

  @doc """
  Returns the stable string id for `actor`.

  ## Examples

      iex> Bandera.Actor.id("user-1")
      "user-1"

      iex> Bandera.Actor.id(42)
      "42"

      iex> Bandera.Actor.id(%{id: 7})
      "7"
  """
  @spec id(t) :: String.t()
  def id(actor)
end

defimpl Bandera.Actor, for: BitString do
  def id(string), do: string
end

defimpl Bandera.Actor, for: Integer do
  def id(int), do: Integer.to_string(int)
end

defimpl Bandera.Actor, for: Map do
  def id(%{id: id}), do: to_string(id)

  def id(map) do
    raise ArgumentError,
          "Bandera.Actor.id/1: map has no :id key — got #{inspect(map)}. " <>
            "Implement the Bandera.Actor protocol for your own struct/type instead."
  end
end
