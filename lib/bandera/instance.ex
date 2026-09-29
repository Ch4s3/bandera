defmodule Bandera.Instance do
  @moduledoc false
  # Supervisor for one Bandera instance: its config registration, read cache,
  # persistence process (if the adapter needs one) and notifier (if enabled).
  # Started via `Bandera.child_spec/1`, a `use Bandera` module, or — for the
  # default instance — by `Bandera.Application` at boot.

  use Supervisor

  alias Bandera.Config
  alias Bandera.Store.Persistent

  require Logger

  @spec child_spec(keyword) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, Config.default_instance()),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @spec start_link(keyword) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    conf = Config.new(opts)
    Supervisor.start_link(__MODULE__, conf, name: conf.supervisor)
  end

  @impl Supervisor
  def init(%Config{} = conf) do
    # The registrar starts first (so the config is readable before any other child
    # starts) and stops last (so it is removed only after they have all stopped).
    children =
      [{Bandera.Instance.Registrar, conf}, {Bandera.Store.Cache, conf}] ++
        persistence_children(conf) ++ notification_children(conf)

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Claim exclusive use of the external storage `id` for `instance`, on behalf of
  the calling process (the claim is released when that process exits).

  Returns `{:error, {:storage_conflict, id, other_instance}}` if another running
  instance already holds it.
  """
  @spec claim_storage(term, atom) :: :ok | {:error, {:storage_conflict, term, atom}}
  def claim_storage(id, instance), do: claim_storage(id, instance, 50)

  defp claim_storage(id, instance, retries) do
    case Registry.register(Bandera.Registry, {:storage, id}, instance) do
      {:ok, _owner} ->
        :ok

      # The Registry drops a dead owner's entries asynchronously, so a claimant
      # restarted by its supervisor can briefly see its own previous incarnation.
      {:error, {:already_registered, pid}} when retries > 0 ->
        if Process.alive?(pid) do
          {:error, {:storage_conflict, id, owner(id, pid)}}
        else
          Process.sleep(10)
          claim_storage(id, instance, retries - 1)
        end

      {:error, {:already_registered, pid}} ->
        {:error, {:storage_conflict, id, owner(id, pid)}}
    end
  end

  defp owner(id, pid) do
    case Registry.lookup(Bandera.Registry, {:storage, id}) do
      [{^pid, instance}] -> instance
      _ -> :unknown
    end
  end

  # Memory owns an ETS table and Redis owns a connection; Ecto uses the host app's
  # own Repo, so Bandera starts nothing for it. A legacy (config-less) adapter is
  # started the way it always was, with no arguments.
  defp persistence_children(%Config{persistence_adapter: adapter} = conf)
       when adapter in [Persistent.Memory, Persistent.Redis] do
    if conf.persistence_legacy?, do: [adapter], else: [{adapter, conf}]
  end

  defp persistence_children(_conf), do: []

  defp notification_children(%Config{notifications_enabled?: false}), do: []

  defp notification_children(%Config{notifications_adapter: adapter} = conf) do
    if Code.ensure_loaded?(adapter) do
      # An adapter with no process of its own (no child_spec/1) needs no child.
      if function_exported?(adapter, :child_spec, 1),
        do: [Bandera.Notifications.child_spec_for(conf)],
        else: []
    else
      Logger.error(
        "[Bandera] notifications are enabled for #{inspect(conf.name)} but the adapter " <>
          "#{inspect(adapter)} is not available. Add its dependency (e.g. :phoenix_pubsub) to your deps."
      )

      []
    end
  end
end
