if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Bandera.Dashboard.Grouping do
    @moduledoc """
    Pure helper that groups flags for the dashboard by a name-prefix convention.

    Each flag's atom name is split (as a string) on the first occurrence of the
    configured separator: the part before it is the group, the remainder is the
    flag's display name. Names without the separator — or with an empty prefix —
    fall into the `"Ungrouped"` bucket, which always sorts last. A `nil` separator
    disables grouping entirely.
    """

    alias Bandera.Flag

    @ungrouped "Ungrouped"

    @typedoc "An ordered group: its name and its `{display_name, flag}` members."
    @type group :: {String.t(), [{String.t(), Flag.t()}]}

    @doc "Groups `flags` using `separator`. See the moduledoc for the rules."
    @spec group([Flag.t()], String.t() | nil) :: [group]
    def group(flags, separator) do
      flags
      |> Enum.map(&classify(&1, separator))
      |> Enum.group_by(fn {group, _display, _flag} -> group end, fn {_group, display, flag} ->
        {display, flag}
      end)
      |> Enum.map(fn {group, members} -> {group, Enum.sort_by(members, &elem(&1, 0))} end)
      |> Enum.sort_by(fn {group, _members} -> sort_key(group) end)
    end

    defp classify(%Flag{name: name} = flag, separator) do
      string = to_string(name)

      case split(string, separator) do
        {group, display} when group != "" -> {group, display, flag}
        _ -> {@ungrouped, string, flag}
      end
    end

    defp split(_string, nil), do: :ungrouped

    defp split(string, separator) do
      case String.split(string, separator, parts: 2) do
        [group, display] -> {group, display}
        [_only] -> :ungrouped
      end
    end

    # Force "Ungrouped" last; otherwise case-insensitive alphabetical.
    defp sort_key(@ungrouped), do: {1, ""}
    defp sort_key(group), do: {0, String.downcase(group)}
  end
end
