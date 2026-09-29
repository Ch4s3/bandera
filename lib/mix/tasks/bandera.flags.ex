defmodule Mix.Tasks.Bandera.Flags do
  @moduledoc """
  List feature flags. Use --stale [--older-than DAYS] to show unused flags.

  Pass `--instance MyApp.Flags` (or `--instance :my_flags` for a plain atom
  instance) to target a named instance instead of the default one.
  """
  @shortdoc "List Bandera feature flags"
  use Mix.Task

  alias Bandera.Config

  # Reserved prefix for segment definitions, which are stored as flags but are not
  # user-facing (kept consistent with Bandera.stale_flags/1).
  @segment_prefix "bandera_segment:"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [stale: :boolean, older_than: :integer, instance: :string]
      )

    Mix.Task.run("app.start")

    instance =
      case opts[:instance] do
        nil -> Config.default_instance()
        str -> parse_instance(str)
      end

    if opts[:stale] && is_nil(Process.whereis(Config.get(instance).usage_server)) do
      Mix.shell().info(
        "[bandera] warning: Bandera.Usage is not running; all flags will appear stale."
      )
    end

    if opts[:stale] do
      Bandera.stale_flags(older_than: opts[:older_than] || 30, instance: instance)
    else
      case Bandera.all_flag_names(instance: instance) do
        {:ok, names} -> Enum.reject(names, &segment_flag?/1)
        _ -> []
      end
    end
    |> Enum.each(&Mix.shell().info(to_string(&1)))
  end

  defp segment_flag?(name), do: String.starts_with?(to_string(name), @segment_prefix)

  # `--instance` is developer input (a CLI flag on a local mix task), never
  # untrusted user input, so String.to_atom is acceptable here. `:my_flags`
  # names a plain atom; anything else names a module.
  defp parse_instance(":" <> rest), do: String.to_atom(rest)
  defp parse_instance("Elixir." <> _ = str), do: String.to_atom(str)
  defp parse_instance(str), do: String.to_atom("Elixir." <> str)
end
