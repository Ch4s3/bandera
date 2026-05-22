defmodule Mix.Tasks.Bandera.Flags do
  @moduledoc "List feature flags. Use --stale [--older-than DAYS] to show unused flags."
  @shortdoc "List Bandera feature flags"
  use Mix.Task

  # Reserved prefix for segment definitions, which are stored as flags but are not
  # user-facing (kept consistent with Bandera.stale_flags/1).
  @segment_prefix "bandera_segment:"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [stale: :boolean, older_than: :integer])
    Mix.Task.run("app.start")

    if opts[:stale] && is_nil(Process.whereis(Bandera.Usage)) do
      Mix.shell().info(
        "[bandera] warning: Bandera.Usage is not running; all flags will appear stale."
      )
    end

    if opts[:stale] do
      Bandera.stale_flags(older_than: opts[:older_than] || 30)
    else
      case Bandera.all_flag_names() do
        {:ok, names} -> Enum.reject(names, &segment_flag?/1)
        _ -> []
      end
    end
    |> Enum.each(&Mix.shell().info(to_string(&1)))
  end

  defp segment_flag?(name), do: String.starts_with?(to_string(name), @segment_prefix)
end
