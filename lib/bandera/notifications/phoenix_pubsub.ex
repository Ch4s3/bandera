if Code.ensure_loaded?(Phoenix.PubSub) do
  defmodule Bandera.Notifications.PhoenixPubSub do
    @moduledoc """
    Phoenix.PubSub cache-busting notifier. Subscribes to its instance's topic and,
    on a flag change broadcast by ANOTHER node, busts that instance's local cache
    entry. Self-published changes are ignored. Each instance publishes on its own
    topic (`Bandera.Notifications.topic/1`: `"bandera:changes"` for the default
    instance, `"bandera:{MyApp.Flags}:changes"` for a named one) and registers under
    its own name (`conf.notifier`: `#{inspect(__MODULE__)}` for the default
    instance). The PubSub server is read at runtime from `conf.notifications[:client]`
    (`config :bandera, cache_bust_notifications: [client: MyApp.PubSub]` for the
    default instance).
    """

    use GenServer
    @behaviour Bandera.Notifications

    alias Bandera.Config
    alias Bandera.Notifications
    alias Bandera.Store.Cache

    @doc """
    Starts the notifier GenServer, which subscribes to the instance's PubSub
    change topic.

    Given a `%Bandera.Config{}` (what the instance supervisor calls), registers as
    `conf.notifier` and subscribes on `Bandera.Notifications.topic(conf)`, using
    the PubSub server `conf.notifications[:client]`. Given a keyword list, starts
    the default instance's notifier (registered as `#{inspect(__MODULE__)}`,
    topic `"bandera:changes"`), as before instances existed.
    """
    @spec start_link(Config.t() | keyword) :: GenServer.on_start()
    def start_link(conf_or_opts \\ [])

    def start_link(%Config{} = conf) do
      GenServer.start_link(__MODULE__, {conf, []}, name: conf.notifier)
    end

    def start_link(opts) when is_list(opts) do
      conf = Config.new()
      GenServer.start_link(__MODULE__, {conf, opts}, name: conf.notifier)
    end

    @doc """
    Child spec for the instance supervisor. The id is `{__MODULE__, conf.name}`
    for a `%Bandera.Config{}`, or `__MODULE__` for keyword options (the default
    instance) — matching `start_link/1`.
    """
    @spec child_spec(Config.t() | keyword) :: Supervisor.child_spec()
    def child_spec(%Config{name: name} = conf) do
      %{id: {__MODULE__, name}, start: {__MODULE__, :start_link, [conf]}}
    end

    def child_spec(opts) when is_list(opts) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
    end

    @impl Bandera.Notifications
    def publish_change(%Config{notifier: notifier}, flag_name) do
      GenServer.call(notifier, {:publish_change, flag_name})
    end

    @impl Bandera.Notifications
    def unique_id(%Config{notifier: notifier}) do
      GenServer.call(notifier, :unique_id)
    end

    # Pre-instance arities, acting on the default instance (backward compatibility).
    @doc false
    @spec publish_change(atom) :: :ok | {:error, term}
    def publish_change(flag_name) when is_atom(flag_name),
      do: publish_change(Config.get(), flag_name)

    @doc false

    @spec unique_id() :: String.t()
    def unique_id, do: unique_id(Config.get())

    @impl GenServer
    def init({%Config{} = conf, _opts}) do
      :ok = Phoenix.PubSub.subscribe(client(conf), Notifications.topic(conf))
      {:ok, %{conf: conf, unique_id: Config.build_unique_id()}}
    end

    @impl GenServer
    def handle_call({:publish_change, flag_name}, _from, %{conf: conf, unique_id: id} = state) do
      # Use broadcast/3 + a per-node unique_id for self-ignore (rather than
      # broadcast_from/4) so the self-ignore mechanism is identical to the Redis
      # adapter, which has no per-subscriber filtering. The unique_id also carries
      # node identity across nodes.
      result =
        Phoenix.PubSub.broadcast(
          client(conf),
          Notifications.topic(conf),
          {:bandera_change, flag_name, id}
        )

      {:reply, result, state}
    end

    def handle_call(:unique_id, _from, %{unique_id: id} = state) do
      {:reply, id, state}
    end

    @impl GenServer
    def handle_info({:bandera_change, _flag, own_id}, %{unique_id: own_id} = state) do
      {:noreply, state}
    end

    def handle_info({:bandera_change, flag, _other_id}, %{conf: conf} = state) do
      Cache.bust(conf, flag)
      {:noreply, state}
    end

    def handle_info(_msg, state), do: {:noreply, state}

    defp client(conf), do: Keyword.fetch!(conf.notifications, :client)
  end
end
