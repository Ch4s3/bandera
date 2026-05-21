if Code.ensure_loaded?(Phoenix.PubSub) do
  defmodule Bandera.Notifications.PhoenixPubSub do
    @moduledoc """
    Phoenix.PubSub cache-busting notifier. Subscribes to a topic and, on a flag
    change broadcast by ANOTHER node, busts the local cache entry. Self-published
    changes are ignored. The PubSub server name is read at runtime from
    `config :bandera, cache_bust_notifications: [client: MyApp.PubSub]`.
    """

    use GenServer
    @behaviour Bandera.Notifications

    alias Bandera.Config
    alias Bandera.Store.Cache

    @topic "bandera:changes"

    @doc "Starts the notifier GenServer, which subscribes to the PubSub change topic."
    @spec start_link(keyword) :: GenServer.on_start()
    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @impl Bandera.Notifications
    def publish_change(flag_name) do
      GenServer.call(__MODULE__, {:publish_change, flag_name})
    end

    @impl Bandera.Notifications
    def unique_id do
      GenServer.call(__MODULE__, :unique_id)
    end

    @impl GenServer
    def init(_opts) do
      :ok = Phoenix.PubSub.subscribe(client(), @topic)
      {:ok, %{unique_id: Config.build_unique_id()}}
    end

    @impl GenServer
    def handle_call({:publish_change, flag_name}, _from, %{unique_id: id} = state) do
      # Use broadcast/3 + a per-node unique_id for self-ignore (rather than
      # broadcast_from/4) so the self-ignore mechanism is identical to the Redis
      # adapter, which has no per-subscriber filtering. The unique_id also carries
      # node identity across nodes.
      result = Phoenix.PubSub.broadcast(client(), @topic, {:bandera_change, flag_name, id})
      {:reply, result, state}
    end

    def handle_call(:unique_id, _from, %{unique_id: id} = state) do
      {:reply, id, state}
    end

    @impl GenServer
    def handle_info({:bandera_change, _flag, own_id}, %{unique_id: own_id} = state) do
      {:noreply, state}
    end

    def handle_info({:bandera_change, flag, _other_id}, state) do
      Cache.bust(flag)
      {:noreply, state}
    end

    def handle_info(_msg, state), do: {:noreply, state}

    defp client, do: Keyword.fetch!(Config.notifications(), :client)
  end
end
