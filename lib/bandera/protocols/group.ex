defprotocol Bandera.Group do
  @moduledoc """
  Determines whether a given item (actor) belongs to a named group.
  Group names are compared as strings.
  """
  @spec in?(t, String.t()) :: boolean
  def in?(item, group_name)
end

defimpl Bandera.Group, for: Map do
  def in?(%{groups: groups}, group_name) when is_list(groups) do
    Enum.any?(groups, fn g -> to_string(g) == group_name end)
  end

  def in?(_, _), do: false
end

defimpl Bandera.Group, for: BitString do
  def in?(_string, _group_name), do: false
end

defimpl Bandera.Group, for: Integer do
  def in?(_int, _group_name), do: false
end
