if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Bandera.Dashboard.Stale do
    @moduledoc """
    Pure helper for stale flag detection in the dashboard.
    Requires `Bandera.Usage` to be running and attached for meaningful results.
    """

    alias Bandera.Config

    @default_older_than 30

    @doc "Returns true if `instance`'s Bandera.Usage GenServer is running."
    @spec usage_available?(atom) :: boolean
    def usage_available?(instance),
      do: not is_nil(Process.whereis(Config.get(instance).usage_server))

    @doc "Returns whether usage tracking is unavailable, loading persisted history, or ready."
    @spec usage_status(atom) :: :unavailable | :loading | :ready
    def usage_status(instance) do
      cond do
        not usage_available?(instance) -> :unavailable
        Bandera.Usage.ready?(instance) -> :ready
        true -> :loading
      end
    catch
      :exit, _reason -> :unavailable
    end

    @doc """
    Returns a MapSet of atom flag names considered stale for `instance`.
    Passes `older_than` (days, default from the instance's `dashboard` config,
    or 30) to `Bandera.stale_flags/1`.
    Returns an empty MapSet if Usage is not running or persisted history is
    still loading.
    """
    @spec stale_set(atom, keyword) :: %MapSet{}
    def stale_set(instance, opts) do
      if usage_status(instance) == :ready do
        days = Keyword.get(opts, :older_than, config_older_than(instance))
        Bandera.stale_flags(older_than: days, instance: instance) |> MapSet.new()
      else
        MapSet.new()
      end
    end

    @doc """
    Returns `{:ok, days}` where days is how long ago the flag was last evaluated
    on `instance`, or `:never` if it has never been evaluated or Usage is not
    running.
    """
    @spec age_days(atom, atom) :: {:ok, non_neg_integer} | :never
    def age_days(instance, flag_name) do
      if usage_available?(instance) do
        case Bandera.Usage.last_evaluated(instance, flag_name) do
          nil -> :never
          at -> {:ok, max(0, floor(DateTime.diff(DateTime.utc_now(), at, :second) / 86_400))}
        end
      else
        :never
      end
    end

    defp config_older_than(instance) do
      instance
      |> Config.get()
      |> Map.fetch!(:dashboard)
      |> Keyword.get(:stale_older_than, @default_older_than)
    end

    # ---- default-instance forms (backward compatibility) ----

    @doc false

    @spec usage_available?() :: boolean
    def usage_available?, do: usage_available?(Bandera.Config.default_instance())

    @doc false

    @spec usage_status() :: :unavailable | :loading | :ready
    def usage_status, do: usage_status(Bandera.Config.default_instance())

    @doc "The default instance's stale set (with `opts`), or `instance`'s. See `stale_set/2`."
    @spec stale_set(keyword | atom) :: %MapSet{}
    def stale_set(opts_or_instance \\ [])
    def stale_set(opts) when is_list(opts), do: stale_set(Bandera.Config.default_instance(), opts)
    def stale_set(instance) when is_atom(instance), do: stale_set(instance, [])

    @doc false

    @spec age_days(atom) :: {:ok, non_neg_integer} | :never
    def age_days(flag_name) when is_atom(flag_name),
      do: age_days(Bandera.Config.default_instance(), flag_name)
  end
end
