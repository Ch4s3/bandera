defmodule Mix.Tasks.Bandera.Flags do
  @moduledoc """
  List feature flags.

  Use `--stale [--older-than DAYS]` to show flags not evaluated within the window
  (defaults to 30 days). Stale detection requires the `Bandera.Usage` tracker to be
  running and attached in your application.

      mix bandera.flags
      mix bandera.flags --stale
      mix bandera.flags --stale --older-than 90
  """
  @shortdoc "List Bandera feature flags"
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [stale: :boolean, older_than: :integer])
    Mix.Task.run("app.start")

    if opts[:stale] do
      Bandera.stale_flags(older_than: opts[:older_than] || 30)
    else
      case Bandera.all_flag_names() do
        {:ok, names} -> names
        _ -> []
      end
    end
    |> Enum.each(&Mix.shell().info(to_string(&1)))
  end
end
