defmodule Bandera.Config do
  @moduledoc """
  Resolves Bandera settings at RUNTIME into a per-instance `%Bandera.Config{}`
  cached in `:persistent_term` for cheap hot-path reads.

  This module deliberately uses NO `Application.compile_env/3`. Every value is read
  at runtime and can be changed via `reload/1`, with no dependency recompilation.
  (Fixes fun_with_flags#122.)

  ## Instances

  Every Bandera call runs against an *instance*, identified by an atom name. The
  default instance is named `Bandera` and is configured from `config :bandera, ...`
  exactly as in single-instance setups; its config is seeded lazily, so it works
  even when no Bandera process has been started (e.g. with the process-scoped test
  store). Named instances are started with `{Bandera, name: MyApp.Flags, ...}` (or
  a `use Bandera` module) and take their settings from the start options, merged
  over `config :my_app, MyApp.Flags, ...` when an `:otp_app` is given. A named
  instance's config exists only while that instance is running.

  The zero-arity accessors (`store/0`, `cache_enabled?/0`, ...) read the default
  instance and exist for backward compatibility; Bandera's own code always passes
  an explicit `%Bandera.Config{}`.
  """

  alias Bandera.Store.Persistent.Memory

  @default_instance Bandera

  # Settings accepted both as `config :bandera, <key>` (default instance) and as
  # instance start options / `config :my_app, MyApp.Flags, <key>` (named instances).
  @settings [
    :store,
    :cache,
    :persistence,
    :cache_bust_notifications,
    :dashboard,
    :auto_create,
    :usage
  ]

  @default_cache [enabled: true, ttl: 900]
  @default_persistence [adapter: Memory]
  @default_store Bandera.Store.TwoLevel
  @default_notifications [enabled: false, adapter: Bandera.Notifications.Redis]
  @default_dashboard [group_separator: "_", theme: :standalone]

  # Access (`conf[:store]`) keeps working code written against the plain-map
  # snapshot `snapshot/0` used to return.
  @behaviour Access

  @enforce_keys [:name]
  defstruct name: @default_instance,
            otp_app: nil,
            start_opts: [],
            store: @default_store,
            store_legacy?: false,
            cache_enabled?: true,
            cache_ttl: 900,
            persistence_adapter: Memory,
            persistence_legacy?: false,
            persistence: @default_persistence,
            notifications_enabled?: false,
            notifications_adapter: Bandera.Notifications.Redis,
            notifications_legacy?: false,
            notifications: @default_notifications,
            group_separator: "_",
            theme: :standalone,
            auto_create: true,
            usage: [],
            dashboard: @default_dashboard,
            namespace: "bandera",
            supervisor: Bandera.Instance,
            cache_table: Bandera.Store.Cache,
            memory_table: Memory,
            redis_conn: Bandera.Store.Persistent.Redis,
            notifier: Bandera.Notifications.Redis,
            usage_server: Bandera.Usage

  @typedoc """
  A resolved instance config.

  Besides the user-facing settings it carries the instance's derived resource
  names. The default instance keeps Bandera's historical names (the ETS table
  `Bandera.Store.Cache`, the Redis keys `bandera:flag:*`, the `"bandera:changes"`
  topic, ...); a named instance `MyApp.Flags` scopes them
  (`MyApp.Flags.Bandera.Store.Cache`, `bandera:{MyApp.Flags}:flag:*`,
  `"bandera:{MyApp.Flags}:changes"`, ...). `namespace` is the prefix for such
  shared, external resource names.

  The `*_legacy?` fields mark a store, persistence adapter, or notifier written
  against the pre-instance (config-less) callbacks; see `Bandera.Store`.
  """
  @type t :: %__MODULE__{
          name: atom,
          otp_app: atom | nil,
          start_opts: keyword,
          store: module,
          store_legacy?: boolean,
          cache_enabled?: boolean,
          cache_ttl: non_neg_integer,
          persistence_adapter: module,
          persistence_legacy?: boolean,
          persistence: keyword,
          notifications_enabled?: boolean,
          notifications_adapter: module,
          notifications_legacy?: boolean,
          notifications: keyword,
          group_separator: String.t() | nil,
          theme: :standalone | :daisyui,
          auto_create: boolean,
          usage: keyword,
          dashboard: keyword,
          namespace: String.t(),
          supervisor: atom,
          cache_table: atom,
          memory_table: atom,
          redis_conn: atom,
          notifier: atom,
          usage_server: atom
        }

  @typedoc "Backward-compatible alias for `t:t/0`."
  @type snapshot :: t

  # ---- instance lifecycle ----

  @doc "The name of the default instance (`Bandera`)."
  @spec default_instance() :: Bandera
  def default_instance, do: @default_instance

  @doc """
  Build an instance config from start options, without storing it.

  Accepts `:name` (default `Bandera`), `:otp_app`, `:defaults`, and the settings
  keys `:store`, `:cache`, `:persistence`, `:cache_bust_notifications`,
  `:dashboard`, `:auto_create`, and `:usage`. Raises `ArgumentError` on unknown
  options.

  Settings are merged, one level deep, from lowest to highest precedence:
  `:defaults` (a keyword list of settings, e.g. an embeddable library's own
  storage config), then application env, then the explicit settings options.
  """
  @spec new(keyword) :: t
  def new(opts \\ []) do
    opts = Keyword.validate!(opts, [:otp_app, :defaults, name: @default_instance] ++ @settings)
    name = Keyword.fetch!(opts, :name)

    unless is_atom(name) and not is_nil(name) and not is_boolean(name) do
      raise ArgumentError, "a Bandera instance name must be an atom, got: #{inspect(name)}"
    end

    build(name, opts, settings(name, opts))
  end

  @doc """
  Return the config for `instance` (default `Bandera`).

  The default instance's config is seeded lazily from application env if it was
  never stored. For a named instance that is not running, raises `ArgumentError`.
  """
  @spec get(atom) :: t
  def get(instance \\ @default_instance) do
    case :persistent_term.get({__MODULE__, instance}, nil) do
      %__MODULE__{} = conf ->
        conf

      nil when instance == @default_instance ->
        # Concurrent cold-start races are benign — both writes produce identical configs.
        conf = new(name: @default_instance)
        put(conf)
        conf

      nil ->
        raise ArgumentError,
              "unknown Bandera instance #{inspect(instance)}: start it in your supervision tree " <>
                "with {Bandera, name: #{inspect(instance)}} (or a `use Bandera` module) first"
    end
  end

  @doc false
  @spec put(t) :: :ok
  def put(%__MODULE__{name: name} = conf), do: :persistent_term.put({__MODULE__, name}, conf)

  @doc false
  @spec erase(atom) :: :ok
  def erase(instance) do
    :persistent_term.erase({__MODULE__, instance})
    :ok
  end

  @doc """
  Re-read `instance`'s settings (application env and start options) and replace
  its stored config. Defaults to the default instance.
  """
  @spec reload(atom) :: :ok
  def reload(instance \\ @default_instance) do
    instance |> get() |> Map.fetch!(:start_opts) |> new() |> put()
  end

  @doc "Return the default instance's config (backward-compatible alias for `get/0`)."
  @spec snapshot() :: t
  def snapshot, do: get(@default_instance)

  @impl Access
  def fetch(%__MODULE__{} = conf, key), do: Map.fetch(conf, key)

  @impl Access
  def get_and_update(%__MODULE__{} = conf, key, fun), do: Map.get_and_update(conf, key, fun)

  @impl Access
  def pop(%__MODULE__{}, key),
    do: raise(ArgumentError, "cannot pop #{inspect(key)} from a %Bandera.Config{}")

  # ---- default-instance accessors (backward compatibility) ----

  @doc "The default instance's active store module (default `Bandera.Store.TwoLevel`)."
  @spec store() :: module
  def store, do: snapshot().store

  @doc "Whether the default instance's read cache is enabled (default `true`)."
  @spec cache_enabled?() :: boolean
  def cache_enabled?, do: snapshot().cache_enabled?

  @doc "The default instance's cache time-to-live in seconds (default `900`)."
  @spec cache_ttl() :: non_neg_integer
  def cache_ttl, do: snapshot().cache_ttl

  @doc "The default instance's persistence adapter (default `Bandera.Store.Persistent.Memory`)."
  @spec persistence_adapter() :: module
  def persistence_adapter, do: snapshot().persistence_adapter

  @doc "The default instance's full persistence keyword config."
  @spec persistence() :: keyword
  def persistence, do: snapshot().persistence

  @doc """
  The SQL table name used by the Ecto adapter (default `"bandera_flags"`) for
  `conf`, or for the default instance when called with no argument.
  """
  @spec ecto_table_name(t) :: String.t()
  def ecto_table_name(conf \\ snapshot()),
    do: Keyword.get(conf.persistence, :ecto_table_name, "bandera_flags")

  @doc "Whether the default instance's cache-busting notifications are enabled (default `false`)."
  @spec notifications_enabled?() :: boolean
  def notifications_enabled?, do: snapshot().notifications_enabled?

  @doc "The default instance's notifications adapter (default `Bandera.Notifications.Redis`)."
  @spec notifications_adapter() :: module
  def notifications_adapter, do: snapshot().notifications_adapter

  @doc "The default instance's full notifications keyword config."
  @spec notifications() :: keyword
  def notifications, do: snapshot().notifications

  @doc "The default instance's dashboard grouping separator (default `\"_\"`; `nil` disables grouping)."
  @spec group_separator() :: String.t() | nil
  def group_separator, do: snapshot().group_separator

  @doc """
  The default instance's dashboard styling theme (default `:standalone`).

  `:standalone` inlines a self-contained stylesheet; `:daisyui` emits daisyUI
  classes and no stylesheet, for apps that build daisyUI themselves. Any other
  value normalizes to `:standalone`.
  """
  @spec theme() :: :standalone | :daisyui
  def theme, do: snapshot().theme

  @doc "Generate a random per-node id used to ignore self-published change notifications."
  @spec build_unique_id() :: String.t()
  def build_unique_id, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  # ---- building ----

  # Lowest to highest precedence: `:defaults`, then application env (the default
  # instance reads `config :bandera, <key>`; a named instance reads
  # `config <otp_app>, <name>, <key>` when it has an :otp_app), then explicit
  # start options. Merged one level deep so `persistence: [ecto_table_name: "x"]`
  # refines the lower layer's persistence settings instead of silently replacing
  # them (and dropping the adapter/repo).
  defp settings(name, opts) do
    defaults = Keyword.validate!(Keyword.get(opts, :defaults, []), @settings)

    env =
      cond do
        name == @default_instance -> Application.get_all_env(:bandera)
        otp_app = opts[:otp_app] -> Application.get_env(otp_app, name, [])
        true -> []
      end

    defaults
    |> merge_settings(Keyword.take(env, @settings))
    |> merge_settings(Keyword.take(opts, @settings))
  end

  defp merge_settings(lower, higher) do
    Keyword.merge(lower, higher, fn _key, low, high ->
      if Keyword.keyword?(low) and Keyword.keyword?(high),
        do: Keyword.merge(low, high),
        else: high
    end)
  end

  defp build(name, opts, settings) do
    cache = Keyword.merge(@default_cache, Keyword.get(settings, :cache, []))
    persistence = Keyword.merge(@default_persistence, Keyword.get(settings, :persistence, []))

    notifications =
      Keyword.merge(@default_notifications, Keyword.get(settings, :cache_bust_notifications, []))

    dashboard = Keyword.merge(@default_dashboard, Keyword.get(settings, :dashboard, []))

    store = Keyword.get(settings, :store, @default_store)
    persistence_adapter = Keyword.fetch!(persistence, :adapter)
    notifications_adapter = Keyword.fetch!(notifications, :adapter)

    %__MODULE__{
      name: name,
      otp_app: opts[:otp_app],
      start_opts: opts,
      store: store,
      store_legacy?: legacy?(store, :lookup, 2),
      cache_enabled?: Keyword.fetch!(cache, :enabled),
      cache_ttl: Keyword.fetch!(cache, :ttl),
      persistence_adapter: persistence_adapter,
      persistence_legacy?: legacy?(persistence_adapter, :get, 2),
      persistence: persistence,
      notifications_enabled?: Keyword.fetch!(notifications, :enabled),
      notifications_adapter: notifications_adapter,
      notifications_legacy?: legacy?(notifications_adapter, :publish_change, 2),
      notifications: notifications,
      group_separator: Keyword.fetch!(dashboard, :group_separator),
      theme: normalize_theme(Keyword.fetch!(dashboard, :theme)),
      auto_create: Keyword.get(settings, :auto_create, true),
      usage: Keyword.get(settings, :usage, []),
      dashboard: dashboard,
      namespace: namespace(name),
      supervisor: scoped(name, Bandera.Instance),
      cache_table: scoped(name, Bandera.Store.Cache),
      memory_table: scoped(name, Memory),
      redis_conn: scoped(name, Bandera.Store.Persistent.Redis),
      notifier: scoped(name, notifications_adapter),
      usage_server: scoped(name, Bandera.Usage)
    }
  end

  # The default instance keeps Bandera's historical (unscoped) names so existing
  # deployments, data, and supervision trees are untouched; named instances prefix
  # every process/table name with the instance name.
  defp scoped(@default_instance, module), do: module
  defp scoped(name, module), do: Module.concat(name, module)

  # Braces keep a named instance's names disjoint from the default instance's
  # (whose Redis keys are `bandera:flag:<name>` — an instance named `:flag` must
  # not produce the same strings), and put all of an instance's Redis keys in one
  # Redis Cluster hash slot.
  defp namespace(@default_instance), do: "bandera"
  defp namespace(name), do: "bandera:{" <> instance_key(name) <> "}"

  # `MyApp.Flags` -> "MyApp.Flags"; `:my_flags` -> "my_flags".
  defp instance_key(name), do: name |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

  # A module implementing only the pre-instance (config-less) callbacks. Detected
  # once, at config build time, so the hot path pays only a struct field read.
  # A module that can't be loaded is not treated as legacy: calls fail exactly as
  # they would have before (e.g. an adapter whose optional dep is missing).
  defp legacy?(module, fun, instance_arity) do
    Code.ensure_loaded?(module) and not function_exported?(module, fun, instance_arity)
  end

  defp normalize_theme(:daisyui), do: :daisyui
  defp normalize_theme(_), do: :standalone
end
