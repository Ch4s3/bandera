if Code.ensure_loaded?(Redix.PubSub) do
  defmodule Bandera.Notifications.Redis do
    @moduledoc """
    Redis PubSub cache-busting notifier (via Redix). Subscribes to its instance's
    channel and, on a flag change published by ANOTHER node, busts that instance's
    local cache entry for that flag. Self-published changes are ignored. Each
    instance publishes on its own channel (`Bandera.Notifications.topic/1`:
    `"bandera:changes"` for the default instance, `"bandera:{MyApp.Flags}:changes"`
    for a named one) and registers under its own name (`conf.notifier`:
    `#{inspect(__MODULE__)}` for the default instance). Connection options are
    read at runtime from `conf.notifications[:redis]` (`config :bandera,
    cache_bust_notifications: [redis: <Redix opts>]` for the default instance).

    Note: incoming change payloads come from a shared channel. The flag name is
    resolved with `String.to_existing_atom/1`, so notifications for flags this node
    has never referenced are ignored (and the atom table can't be exhausted by
    foreign publishers).
    """

    use GenServer
    @behaviour Bandera.Notifications

    alias Bandera.Config
    alias Bandera.Notifications
    alias Bandera.Store.Cache

    @doc """
    Starts the notifier GenServer, which opens its own Redis pub and sub
    connections.

    Given a `%Bandera.Config{}` (what the instance supervisor calls), registers as
    `conf.notifier`, subscribes on `Bandera.Notifications.topic(conf)`, and reads
    connection options from `conf.notifications[:redis]`. Given a keyword list,
    starts the default instance's notifier (registered as `#{inspect(__MODULE__)}`,
    channel `"bandera:changes"`), with `opts` merged over `config :bandera,
    cache_bust_notifications: [redis: ...]`, as before instances existed.
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

    @doc "Whether the default instance's Redis subscription has been confirmed (useful in tests)."
    @spec subscribed?() :: boolean
    def subscribed?, do: subscribed?(Config.default_instance())

    @doc "Whether `instance`'s Redis subscription has been confirmed (useful in tests)."
    @spec subscribed?(atom) :: boolean
    def subscribed?(instance) do
      GenServer.call(Config.get(instance).notifier, :subscribed?)
    end

    @impl GenServer
    def init({%Config{} = conf, opts}) do
      redis_opts = conf.notifications |> Keyword.get(:redis, []) |> Keyword.merge(opts)
      channel = Notifications.topic(conf)
      {:ok, pub} = Redix.start_link(redis_opts)
      {:ok, sub} = Redix.PubSub.start_link(redis_opts)
      {:ok, _ref} = Redix.PubSub.subscribe(sub, channel, self())

      {:ok,
       %{
         conf: conf,
         channel: channel,
         unique_id: Config.build_unique_id(),
         pub: pub,
         sub: sub,
         subscribed: false
       }}
    end

    @impl GenServer
    def handle_call(
          {:publish_change, flag_name},
          _from,
          %{pub: pub, channel: channel, unique_id: id} = state
        ) do
      result = Redix.command(pub, ["PUBLISH", channel, "#{id}:#{flag_name}"])
      {:reply, normalize(result), state}
    end

    def handle_call(:unique_id, _from, %{unique_id: id} = state) do
      {:reply, id, state}
    end

    def handle_call(:subscribed?, _from, state) do
      {:reply, state.subscribed, state}
    end

    @impl GenServer
    def handle_info(
          {:redix_pubsub, _pid, _ref, :message, %{channel: channel, payload: payload}},
          %{channel: channel} = state
        ) do
      handle_payload(payload, state.unique_id, state.conf)
      {:noreply, state}
    end

    def handle_info(
          {:redix_pubsub, _pid, _ref, :subscribed, %{channel: channel}},
          %{channel: channel} = state
        ) do
      {:noreply, %{state | subscribed: true}}
    end

    def handle_info({:redix_pubsub, _pid, _ref, _kind, _meta}, state) do
      {:noreply, state}
    end

    defp handle_payload(payload, own_id, conf) do
      case String.split(payload, ":", parts: 2) do
        [^own_id, _flag] -> :ok
        [_other_id, flag] -> bust(conf, flag)
        _ -> :ok
      end
    end

    # The flag name arrives over a shared channel that other (or misbehaving)
    # publishers could write to. Use String.to_existing_atom/1 to avoid atom-table
    # exhaustion: an unknown flag name means this node has never referenced that
    # flag, so there is nothing cached to bust — drop it silently.
    defp bust(conf, flag) do
      Cache.bust(conf, String.to_existing_atom(flag))
    rescue
      ArgumentError -> :ok
    end

    defp normalize({:ok, _}), do: :ok
    defp normalize({:error, reason}), do: {:error, reason}
  end
end
