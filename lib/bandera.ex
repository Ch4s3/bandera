defmodule Bandera do
  @moduledoc """
  Runtime-configured feature flags, API-compatible with fun_with_flags.

  The active store is resolved at runtime (per instance, via `Bandera.Config`), so
  nothing about persistence or caching is fixed at compile time.

  ## Instances

  Every function here accepts an `instance:` option naming the Bandera instance
  to use. It defaults to `Bandera`, the default instance configured by
  `config :bandera, ...`, so single-instance apps never pass it.

  To run several isolated flag sets in one VM (e.g. one per app in an umbrella),
  define a module per instance and start it in that app's supervision tree:

      defmodule MyApp.Flags do
        use Bandera, otp_app: :my_app
      end

      # config/config.exs
      config :my_app, MyApp.Flags,
        persistence: [adapter: Bandera.Store.Persistent.Ecto, repo: MyApp.Repo,
                      ecto_table_name: "my_app_flags"]

      # application.ex
      children = [MyApp.Repo, MyApp.Flags]

  `MyApp.Flags` exposes this module's API (`MyApp.Flags.enabled?(:checkout)`,
  ...) bound to its own instance: its own cache, storage, notifications, and
  telemetry `instance` metadata. `{Bandera, name: MyApp.Flags, ...}` starts the
  same instance without a module; pass `instance: MyApp.Flags` to call it.
  """

  alias Bandera.Config
  alias Bandera.Flag
  alias Bandera.Gate
  alias Bandera.Store
  require Logger

  @doc """
  Defines a module bound to its own Bandera instance, named after the module.

      defmodule MyApp.Flags do
        use Bandera, otp_app: :my_app
      end

  The module gets `child_spec/1` and `start_link/1` (add `MyApp.Flags` to your
  supervision tree), plus every public function of `Bandera` (`enabled?/2`,
  `enable/2`, `disable/2`, `clear/2`, `variant/2`, `put_variants/3`,
  `put_segment/3`, `all_flag_names/1`, `all_flags/1`, `get_flag/2`,
  `stale_flags/1`, `reload_config/1`) with the instance filled in.

  The instance is configured, at runtime, from `config :my_app, MyApp.Flags, ...`
  (the same keys as `config :bandera`), with any options given to `child_spec/1`
  taking precedence. `:otp_app` is optional; without it only the child spec
  options are used.

  `:defaults` sets the instance's lowest-precedence settings, below application
  env. It suits a library meant to be embedded in other applications: the
  library ships its own storage and notification settings, and an embedding
  host overrides only what it must (e.g. a test store) via
  `config :the_library, TheLibrary.Flags, ...`, without having to mirror the rest:

      defmodule MyLib.Flags do
        use Bandera,
          otp_app: :my_lib,
          defaults: [
            persistence: [adapter: Bandera.Store.Persistent.Ecto, repo: MyLib.Repo,
                          prefix: "my_lib"]
          ]
      end
  """
  defmacro __using__(opts) do
    otp_app = Keyword.get(opts, :otp_app)
    defaults = Keyword.get(opts, :defaults, [])

    quote bind_quoted: [otp_app: otp_app, defaults: defaults] do
      # Only the app name and the module's own default settings are fixed at
      # compile time; application env is read when the instance starts (Bandera
      # never uses compile-time config).
      @bandera_defaults defaults
      @bandera_base_opts if(otp_app, do: [otp_app: otp_app], else: []) ++ [defaults: defaults]

      @doc false
      # The settings this module ships as its instance's lowest-precedence layer.
      def __bandera_defaults__, do: @bandera_defaults

      @doc "Child spec for this module's Bandera instance. See `Bandera.child_spec/1`."
      @spec child_spec(keyword) :: Supervisor.child_spec()
      def child_spec(opts \\ []), do: Bandera.child_spec(__bandera_start_opts__(opts))

      @doc "Starts this module's Bandera instance. See `Bandera.start_link/1`."
      @spec start_link(keyword) :: Supervisor.on_start()
      def start_link(opts \\ []), do: Bandera.start_link(__bandera_start_opts__(opts))

      defp __bandera_start_opts__(opts),
        do: @bandera_base_opts |> Keyword.merge(opts) |> Keyword.put(:name, __MODULE__)

      @doc "See `Bandera.enabled?/2`."
      def enabled?(flag_name, opts \\ []),
        do: Bandera.enabled?(flag_name, [{:instance, __MODULE__} | opts])

      @doc "See `Bandera.enable/2`."
      def enable(flag_name, opts \\ []),
        do: Bandera.enable(flag_name, [{:instance, __MODULE__} | opts])

      @doc "See `Bandera.disable/2`."
      def disable(flag_name, opts \\ []),
        do: Bandera.disable(flag_name, [{:instance, __MODULE__} | opts])

      @doc "See `Bandera.clear/2`."
      def clear(flag_name, opts \\ []),
        do: Bandera.clear(flag_name, [{:instance, __MODULE__} | opts])

      @doc "See `Bandera.variant/2`."
      def variant(flag_name, opts \\ []),
        do: Bandera.variant(flag_name, [{:instance, __MODULE__} | opts])

      @doc "See `Bandera.put_variants/3`."
      def put_variants(flag_name, weights, opts \\ []),
        do: Bandera.put_variants(flag_name, weights, [{:instance, __MODULE__} | opts])

      @doc "See `Bandera.put_segment/3`."
      def put_segment(name, constraints, opts \\ []),
        do: Bandera.put_segment(name, constraints, [{:instance, __MODULE__} | opts])

      @doc "See `Bandera.all_flag_names/1`."
      def all_flag_names(opts \\ []), do: Bandera.all_flag_names([{:instance, __MODULE__} | opts])

      @doc "See `Bandera.all_flags/1`."
      def all_flags(opts \\ []), do: Bandera.all_flags([{:instance, __MODULE__} | opts])

      @doc "See `Bandera.get_flag/2`."
      def get_flag(flag_name, opts \\ []),
        do: Bandera.get_flag(flag_name, [{:instance, __MODULE__} | opts])

      @doc "See `Bandera.stale_flags/1`."
      def stale_flags(opts \\ []), do: Bandera.stale_flags([{:instance, __MODULE__} | opts])

      @doc "See `Bandera.reload_config/1`."
      def reload_config(opts \\ []), do: Bandera.reload_config([{:instance, __MODULE__} | opts])
    end
  end

  # ---- instances ----

  @doc """
  Child spec for a Bandera instance.

  Options: `:name` (the instance name, default `Bandera`), `:otp_app` (read
  settings from `config otp_app, name, ...`), and any of the `config :bandera`
  settings (`:store`, `:cache`, `:persistence`, `:cache_bust_notifications`,
  `:dashboard`, `:auto_create`, `:usage`), which take precedence over
  application env. The default instance is started at boot unless
  `config :bandera, start_on_boot: false`.

  An instance whose storage is already used by another running instance (e.g.
  the same Ecto repo and table) refuses to start.

      children = [{Bandera, name: MyApp.Flags, persistence: [adapter: Bandera.Store.Persistent.Memory]}]
  """
  @spec child_spec(keyword) :: Supervisor.child_spec()
  def child_spec(opts \\ []), do: Bandera.Instance.child_spec(opts)

  @doc "Starts a Bandera instance (see `child_spec/1` for options)."
  @spec start_link(keyword) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Bandera.Instance.start_link(opts)

  @doc """
  Re-read application env (and start options) into the runtime config of the
  default instance, or of `instance:`.
  """
  @spec reload_config(keyword) :: :ok
  def reload_config(opts \\ []),
    do: opts |> Keyword.get(:instance, Config.default_instance()) |> Config.reload()

  # ---- enabled? ----

  @doc """
  Returns whether `flag_name` is enabled.

  Pass `for: actor` to evaluate actor, group, and percentage-of-actors gates against
  a specific subject (the actor is identified via the `Bandera.Actor`/`Bandera.Group`
  protocols). The flag is read through the active store (cache included). A missing
  flag, or a store lookup error, resolves to `false` (the error is logged).

  Pass `default: true` to fail open (return true) when the store is unreachable; the
  default is false.

  ## Examples

      iex> Bandera.enabled?(:unknown_flag)
      false

      iex> Bandera.enable(:checkout)
      iex> Bandera.enabled?(:checkout)
      true

      iex> Bandera.enable(:beta, for_actor: "user-1")
      iex> Bandera.enabled?(:beta, for: "user-1")
      true
      iex> Bandera.enabled?(:beta, for: "user-2")
      false
  """
  @spec enabled?(atom, keyword) :: boolean
  def enabled?(flag_name, options \\ [])

  def enabled?(flag_name, options) when is_atom(flag_name) do
    {conf, options} = pop_conf(options)
    {default, rest} = Keyword.pop(options, :default, false)
    eval_opts = rest |> Keyword.take([:for, :context]) |> drop_nil_for()

    result =
      case Store.lookup(conf, flag_name) do
        {:ok, %Flag{gates: []} = _flag} ->
          maybe_auto_create(conf, flag_name)
          false

        {:ok, flag} ->
          if prerequisites_met?(conf, flag, eval_opts, [flag_name]) do
            Flag.enabled?(expand_segments(conf, flag), eval_opts)
          else
            false
          end

        error ->
          lookup_failed(flag_name, error, default)
      end

    track_enabled?(conf, flag_name, eval_opts, result)
  end

  defp drop_nil_for(opts) do
    case Keyword.fetch(opts, :for) do
      {:ok, nil} -> Keyword.delete(opts, :for)
      _ -> opts
    end
  end

  @segment_prefix "bandera_segment:"

  # Expand each :segment gate into the referenced segment's :rule gate so the pure
  # Flag evaluator can resolve it. Unresolvable segments are dropped (ignored).
  defp expand_segments(conf, %Flag{gates: gates} = flag) do
    expanded =
      Enum.flat_map(gates, fn
        %Gate{type: :segment, for: name, enabled: enabled} ->
          case Store.lookup(conf, String.to_atom(@segment_prefix <> name)) do
            {:ok, %Flag{gates: seg_gates}} ->
              case Enum.find(seg_gates, &Gate.rule?/1) do
                %Gate{value: constraints} -> [Gate.new(:rule, constraints, enabled)]
                _ -> []
              end

            _ ->
              []
          end

        gate ->
          [gate]
      end)

    %{flag | gates: expanded}
  end

  defp track_enabled?(conf, flag_name, options, result) do
    Bandera.Telemetry.event([:enabled?], %{
      flag_name: flag_name,
      options: options,
      result: result,
      instance: conf.name
    })

    result
  end

  # ---- enable ----

  @doc """
  Enables `flag_name`, optionally scoped by an option, and returns `{:ok, enabled?}`.

  With no options the boolean gate is turned on. Supported scopes:

    * `for_actor: actor` — enable for one actor
    * `for_group: group` — enable for a named group
    * `for_percentage_of: {:time, ratio}` — enable for a ratio of calls
    * `for_percentage_of: {:actors, ratio}` — enable for a ratio of actors
    * `when: constraints` — enable when the evaluation context matches a rule
    * `for_segment: name` — enable for a reusable named segment
    * `requires: parent` (or `{parent, required_state}`) — add a prerequisite
    * `schedule: {from, until}` — enable inside an ISO-8601 time window

  `ratio` is a float in `0.0 < r < 1.0`. The write goes to the persistent store and
  busts/refreshes the cache; returns `{:error, reason}` if the store write fails.

  The returned `enabled?` is the immediate state for unconditional/percentage gates.
  For the **conditional** scopes (`when:`, `for_segment:`, `requires:`, `schedule:`)
  it is `true` to signal a successful write — those gates are evaluated per call by
  `enabled?/2` against the relevant context, actor, time, or parent flag.

  Pass `by: identity` to record who made the change; it is carried in the write
  telemetry metadata (see `Bandera.Audit`) and does not affect the gate written.

  ## Examples

      iex> Bandera.enable(:checkout)
      {:ok, true}

      iex> Bandera.enable(:beta, for_actor: "user-1")
      {:ok, true}

      iex> Bandera.enable(:gradual, for_percentage_of: {:actors, 0.25})
      {:ok, true}
  """
  @spec enable(atom, keyword) :: {:ok, boolean} | {:error, term}
  def enable(flag_name, options \\ [])

  def enable(flag_name, options) when is_atom(flag_name) do
    {conf, options} = pop_conf(options)
    {_by, rest} = Keyword.pop(options, :by)
    meta = %{flag_name: flag_name, options: options, instance: conf.name}

    Bandera.Telemetry.span([:enable], meta, fn ->
      result = do_enable(conf, flag_name, rest)
      {result, %{result: result}}
    end)
  end

  defp do_enable(conf, flag_name, []) when is_atom(flag_name),
    do: put_and_verify(conf, flag_name, Gate.new(:boolean, true), [])

  defp do_enable(conf, flag_name, for_actor: nil), do: do_enable(conf, flag_name, [])

  defp do_enable(conf, flag_name, for_actor: actor) when is_atom(flag_name),
    do: put_and_verify(conf, flag_name, Gate.new(:actor, actor, true), for: actor)

  defp do_enable(conf, flag_name, for_group: nil), do: do_enable(conf, flag_name, [])

  defp do_enable(conf, flag_name, for_group: group_name) when is_atom(flag_name),
    do: put_constant(conf, flag_name, Gate.new(:group, group_name, true), true)

  defp do_enable(conf, flag_name, for_percentage_of: {:time, ratio}) when is_atom(flag_name),
    do: put_constant(conf, flag_name, Gate.new(:percentage_of_time, ratio), true)

  defp do_enable(conf, flag_name, for_percentage_of: {:actors, ratio}) when is_atom(flag_name),
    do: put_constant(conf, flag_name, Gate.new(:percentage_of_actors, ratio), true)

  defp do_enable(_conf, _flag_name, when: []),
    do: raise(ArgumentError, "enable/2 :when requires at least one constraint")

  defp do_enable(conf, flag_name, when: constraints)
       when is_atom(flag_name) and is_list(constraints) do
    gate = Gate.new(:rule, Enum.map(constraints, &to_constraint/1), true)
    put_constant(conf, flag_name, gate, true)
  end

  defp do_enable(conf, flag_name, for_segment: name) when is_atom(flag_name),
    do: put_constant(conf, flag_name, Gate.new(:segment, name, true), true)

  defp do_enable(conf, flag_name, schedule: {from, until}) when is_atom(flag_name),
    do: put_constant(conf, flag_name, Gate.new(:schedule, {from, until}), true)

  defp do_enable(conf, flag_name, requires: parent) when is_atom(flag_name) and is_atom(parent),
    do: put_constant(conf, flag_name, Gate.new(:prerequisite, parent, true), true)

  defp do_enable(conf, flag_name, requires: {parent, required})
       when is_atom(flag_name) and is_atom(parent) and is_boolean(required),
       do: put_constant(conf, flag_name, Gate.new(:prerequisite, parent, required), true)

  defp to_constraint(%Bandera.Constraint{} = c), do: c

  defp to_constraint({attribute, operator, value}),
    do: Bandera.Constraint.new(attribute, operator, value)

  # ---- disable ----

  @doc """
  Disables `flag_name`, optionally scoped by an option, and returns `{:ok, enabled?}`.

  Accepts the negatable scopes `for_actor:`, `for_group:`, and `for_percentage_of:`
  (for a percentage scope, disabling for `ratio` is equivalent to enabling for
  `1.0 - ratio`). To remove a grant-only gate (`variant`, `rule`, `segment`,
  `prerequisite`, `schedule`), use `clear/2`; passing one of those scopes here
  returns `{:error, :unsupported_scope}`. Returns `{:error, reason}` on a store
  write failure.

  Accepts `by: identity` to record who made the change (see `Bandera.Audit`).

  ## Examples

      iex> Bandera.disable(:checkout)
      {:ok, false}

      iex> Bandera.enable(:beta)
      iex> Bandera.disable(:beta)
      {:ok, false}
  """
  @spec disable(atom, keyword) :: {:ok, boolean} | {:error, term}
  def disable(flag_name, options \\ [])

  def disable(flag_name, options) when is_atom(flag_name) do
    {conf, options} = pop_conf(options)
    {_by, rest} = Keyword.pop(options, :by)
    meta = %{flag_name: flag_name, options: options, instance: conf.name}

    Bandera.Telemetry.span([:disable], meta, fn ->
      result = do_disable(conf, flag_name, rest)
      {result, %{result: result}}
    end)
  end

  defp do_disable(conf, flag_name, []) when is_atom(flag_name),
    do: put_and_verify(conf, flag_name, Gate.new(:boolean, false), [])

  defp do_disable(conf, flag_name, for_actor: nil), do: do_disable(conf, flag_name, [])

  defp do_disable(conf, flag_name, for_actor: actor) when is_atom(flag_name),
    do: put_and_verify(conf, flag_name, Gate.new(:actor, actor, false), for: actor)

  defp do_disable(conf, flag_name, for_group: nil), do: do_disable(conf, flag_name, [])

  defp do_disable(conf, flag_name, for_group: group_name) when is_atom(flag_name),
    do: put_constant(conf, flag_name, Gate.new(:group, group_name, false), false)

  defp do_disable(conf, flag_name, for_percentage_of: {type, ratio})
       when is_atom(flag_name) and is_float(ratio) do
    case do_enable(conf, flag_name, for_percentage_of: {type, 1.0 - ratio}) do
      {:ok, true} -> {:ok, false}
      error -> error
    end
  end

  defp do_disable(_conf, _flag_name, _options), do: {:error, :unsupported_scope}

  # ---- clear ----

  @doc """
  Removes gates from `flag_name`, returning `:ok`.

  With no options the whole flag (all its gates) is deleted. A scope removes just
  that gate, letting evaluation fall through to whatever remains:

    * `boolean: true` — clear the boolean gate
    * `for_actor: actor` — clear one actor gate
    * `for_group: group` — clear one group gate
    * `for_percentage: true` — clear the percentage gate
    * `variant: true` — clear the variant gate
    * `rule: true` — clear the rule gate
    * `for_segment: name` — clear one segment gate
    * `requires: parent` — clear one prerequisite gate
    * `schedule: true` — clear the schedule gate

  Accepts `by: identity` to record who made the change (see `Bandera.Audit`).

  Returns `{:error, reason}` if the store delete fails.

  ## Examples

      iex> Bandera.enable(:checkout)
      iex> Bandera.clear(:checkout)
      :ok
      iex> Bandera.enabled?(:checkout)
      false
  """
  @spec clear(atom, keyword) :: :ok | {:error, term}
  def clear(flag_name, options \\ [])

  def clear(flag_name, options) when is_atom(flag_name) do
    {conf, options} = pop_conf(options)
    {_by, rest} = Keyword.pop(options, :by)
    meta = %{flag_name: flag_name, options: options, instance: conf.name}

    Bandera.Telemetry.span([:clear], meta, fn ->
      result = do_clear(conf, flag_name, rest)
      {result, %{result: result}}
    end)
  end

  defp do_clear(conf, flag_name, []) when is_atom(flag_name) do
    case Store.delete(conf, flag_name) do
      {:ok, _flag} -> :ok
      error -> error
    end
  end

  defp do_clear(conf, flag_name, boolean: true),
    do: clear_gate(conf, flag_name, Gate.new(:boolean, false))

  defp do_clear(conf, flag_name, for_actor: nil), do: do_clear(conf, flag_name, [])

  defp do_clear(conf, flag_name, for_actor: actor) when is_atom(flag_name),
    do: clear_gate(conf, flag_name, Gate.new(:actor, actor, false))

  defp do_clear(conf, flag_name, for_group: nil), do: do_clear(conf, flag_name, [])

  defp do_clear(conf, flag_name, for_group: group_name) when is_atom(flag_name),
    do: clear_gate(conf, flag_name, Gate.new(:group, group_name, false))

  defp do_clear(conf, flag_name, for_percentage: true),
    do: clear_gate(conf, flag_name, Gate.new(:percentage_of_time, 0.5))

  # Gate.new/2 for :variant requires a positive-weight map, so build the struct;
  # Gate.id/1 derives the slot id from the type alone, making the value irrelevant.
  defp do_clear(conf, flag_name, variant: true),
    do: clear_gate(conf, flag_name, %Gate{type: :variant, enabled: false})

  defp do_clear(conf, flag_name, rule: true),
    do: clear_gate(conf, flag_name, Gate.new(:rule, [], false))

  defp do_clear(conf, flag_name, for_segment: name) when is_atom(flag_name),
    do: clear_gate(conf, flag_name, Gate.new(:segment, name, false))

  defp do_clear(conf, flag_name, schedule: true),
    do: clear_gate(conf, flag_name, Gate.new(:schedule, {nil, nil}))

  defp do_clear(conf, flag_name, requires: parent) when is_atom(flag_name) and is_atom(parent),
    do: clear_gate(conf, flag_name, Gate.new(:prerequisite, parent, false))

  # The required state is not part of the prerequisite gate's slot id, so the tuple
  # form clears the same gate as the bare-atom form — accepted for symmetry with enable/2.
  defp do_clear(conf, flag_name, requires: {parent, _required}) when is_atom(flag_name),
    do: do_clear(conf, flag_name, requires: parent)

  defp do_clear(_conf, _flag_name, _options), do: {:error, :unsupported_scope}

  # ---- variant ----

  @doc """
  Returns the variant chosen for the flag named `flag_name` (bucketed by the actor
  passed via `for:`), or `options[:default]` (nil if not given) when the flag is
  missing, has no variant gate, or `for:` is absent or `nil`.

  Looks up the flag from the active store and delegates to `Flag.variant/2`. A missing
  flag or store lookup error returns `options[:default]` (the error is logged).

  ## Examples

      iex> Bandera.put_variants(:ab_test, %{"a" => 1, "b" => 1})
      iex> Bandera.variant(:ab_test, for: %{id: 1}) in ["a", "b"]
      true
  """
  @spec variant(atom, keyword) :: term
  def variant(flag_name, options \\ []) when is_atom(flag_name) do
    {conf, options} = pop_conf(options)
    default = Keyword.get(options, :default)

    result =
      case Store.lookup(conf, flag_name) do
        {:ok, flag} -> Flag.variant(flag, options)
        error -> variant_lookup_failed(flag_name, error, default)
      end

    Bandera.Telemetry.event([:variant], %{
      flag_name: flag_name,
      options: options,
      result: result,
      instance: conf.name
    })

    result
  end

  @doc """
  Stores a `:variant` gate for `flag_name` with the given `weights` map.

  `weights` is a `%{variant_name => weight}` map; actors are bucketed proportionally
  by weight using a stable SHA-256 hash per actor+flag. Returns `{:ok, flag}` on
  success, `{:error, reason}` on a store write failure.

  The optional third argument accepts `instance:`; any other option is ignored.
  `put_variants` does not support `by:` and is not audited by `Bandera.Audit`.

  ## Examples

      iex> {:ok, flag} = Bandera.put_variants(:hero, %{"blue" => 1, "green" => 1})
      iex> flag.name
      :hero
  """
  @spec put_variants(atom, %{optional(String.t()) => number}, keyword) ::
          {:ok, Flag.t()} | {:error, term}
  def put_variants(flag_name, weights, options \\ [])
      when is_atom(flag_name) and is_map(weights) do
    {conf, _options} = pop_conf(options)
    meta = %{flag_name: flag_name, weights: weights, instance: conf.name}

    Bandera.Telemetry.span([:put_variants], meta, fn ->
      result = Store.put(conf, flag_name, Gate.new(:variant, weights))
      {result, %{result: result}}
    end)
  end

  defp variant_lookup_failed(flag_name, error, default) do
    Logger.warning("[Bandera] variant lookup for #{inspect(flag_name)} failed: #{inspect(error)}")
    default
  end

  # ---- segments ----

  @doc """
  Stores a reusable named constraint set (a segment) under the reserved key
  `:"bandera_segment:<name>"`.

  Segments are referenced from flags via `enable(flag, for_segment: name)` and are
  expanded at evaluation time so that `Flag` stays pure. `name` must be a
  developer-defined atom — never untrusted user input. Segments belong to an
  instance (pass `instance:` to target a named one).

  ## Examples

      iex> {:ok, _} = Bandera.put_segment(:premium, [{"plan", :eq, "premium"}])
      iex> {:ok, _flag} = Bandera.get_flag(:"bandera_segment:premium")
  """
  @spec put_segment(atom, [tuple | Bandera.Constraint.t()], keyword) ::
          {:ok, Flag.t()} | {:error, term}
  def put_segment(name, constraints, options \\ [])

  def put_segment(_name, [], _options),
    do: raise(ArgumentError, "put_segment/2 requires at least one constraint")

  def put_segment(name, constraints, options) when is_atom(name) and is_list(constraints) do
    {conf, _options} = pop_conf(options)
    gate = Gate.new(:rule, Enum.map(constraints, &to_constraint/1), true)
    Store.put(conf, segment_key(name), gate)
  end

  defp segment_key(name), do: String.to_atom(@segment_prefix <> to_string(name))

  # ---- introspection ----

  @doc """
  Returns `{:ok, names}` with every known flag name, or `{:error, reason}`.

  ## Examples

      iex> Bandera.enable(:checkout)
      iex> Bandera.all_flag_names()
      {:ok, [:checkout]}
  """
  @spec all_flag_names(keyword) :: {:ok, [atom]} | {:error, term}
  def all_flag_names(options \\ []) do
    {conf, _options} = pop_conf(options)
    Store.all_flag_names(conf)
  end

  @doc """
  Returns `{:ok, flags}` with every stored `Bandera.Flag`, or `{:error, reason}`.

  ## Examples

      iex> Bandera.enable(:checkout)
      iex> {:ok, flags} = Bandera.all_flags()
      iex> Enum.map(flags, & &1.name)
      [:checkout]
  """
  @spec all_flags(keyword) :: {:ok, [Flag.t()]} | {:error, term}
  def all_flags(options \\ []) do
    {conf, _options} = pop_conf(options)
    Store.all_flags(conf)
  end

  @doc """
  Looks up a single flag, returning `{:ok, %Bandera.Flag{}}` or `{:error, reason}`.

  An unknown flag still returns `{:ok, flag}` with an empty gate list (a disabled
  flag), not an error.

  ## Examples

      iex> Bandera.enable(:checkout)
      iex> {:ok, flag} = Bandera.get_flag(:checkout)
      iex> flag.gates
      [%Bandera.Gate{type: :boolean, for: nil, enabled: true}]

      iex> {:ok, flag} = Bandera.get_flag(:unknown_flag)
      iex> flag.gates
      []
  """
  @spec get_flag(atom, keyword) :: {:ok, Flag.t()} | {:error, term}
  def get_flag(flag_name, options \\ []) when is_atom(flag_name) do
    {conf, _options} = pop_conf(options)
    Store.lookup(conf, flag_name)
  end

  # ---- helpers ----

  # Resolve the `instance:` option (default: the default instance) to its config
  # and return the remaining options. Every public entry point calls this exactly
  # once and threads the config down; nothing below reads a global.
  defp pop_conf(options) do
    {instance, rest} = Keyword.pop(options, :instance, Config.default_instance())
    {Config.get(instance), rest}
  end

  defp put_and_verify(conf, flag_name, gate, verify_opts) do
    case Store.put(conf, flag_name, gate) do
      {:ok, flag} -> {:ok, Flag.enabled?(flag, verify_opts)}
      error -> error
    end
  end

  defp put_constant(conf, flag_name, gate, result) do
    case Store.put(conf, flag_name, gate) do
      {:ok, _flag} -> {:ok, result}
      error -> error
    end
  end

  defp clear_gate(conf, flag_name, gate) do
    case Store.delete(conf, flag_name, gate) do
      {:ok, _flag} -> :ok
      error -> error
    end
  end

  @doc """
  List flags whose last evaluation is older than `older_than` days (or never
  evaluated). Requires `Bandera.Usage` to be running for the instance.
  """
  @spec stale_flags(keyword) :: [atom]
  def stale_flags(opts \\ []) do
    {conf, opts} = pop_conf(opts)
    # Clamp to >= 0 so a negative window can't push the cutoff into the future (which
    # would report every flag, even freshly-evaluated ones, as stale).
    days = opts |> Keyword.get(:older_than, 30) |> max(0)
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    case Store.all_flag_names(conf) do
      {:ok, names} ->
        names
        |> Enum.reject(&segment_flag?/1)
        |> Enum.filter(fn name ->
          case safe_last_evaluated(conf, name) do
            nil -> true
            at -> DateTime.compare(at, cutoff) == :lt
          end
        end)

      _ ->
        []
    end
  end

  # Internal segment definitions are stored as reserved flags and are never
  # evaluated via enabled?/2, so they would always look stale — exclude them.
  defp segment_flag?(name), do: String.starts_with?(to_string(name), @segment_prefix)

  # Reads the instance's Usage tracker, returning nil when it isn't running.
  defp safe_last_evaluated(conf, flag_name) do
    Bandera.Usage.last_evaluated(conf, flag_name)
  rescue
    ArgumentError -> nil
  end

  defp prerequisites_met?(conf, flag, eval_opts, visited) do
    {status, _memo} = prereqs_status(conf, flag, eval_opts, visited, %{})
    status == :ok
  end

  # Status of a flag's prerequisite gates: :ok (all met), :not_met (a parent is in the
  # wrong state), or :cycle (resolving a parent re-entered a flag already on the stack).
  # A cycle propagates as :cycle so it fails closed uniformly — including required:false
  # edges, which a plain false would otherwise satisfy.
  defp prereqs_status(conf, %Flag{gates: gates}, eval_opts, visited, memo) do
    gates
    |> Enum.filter(&Gate.prerequisite?/1)
    |> Enum.reduce_while({:ok, memo}, fn %Gate{for: parent, enabled: required}, {_status, m} ->
      cond do
        # An unresolved parent (e.g. an unknown atom from corrupt store data) fails closed.
        not is_atom(parent) ->
          {:halt, {:not_met, m}}

        true ->
          case resolve(conf, parent, eval_opts, visited, m) do
            {{:ok, enabled}, m} when enabled == required -> {:cont, {:ok, m}}
            {{:ok, _enabled}, m} -> {:halt, {:not_met, m}}
            {:cycle, m} -> {:halt, {:cycle, m}}
          end
      end
    end)
  end

  # Resolve a flag's effective enabled state, carrying a per-evaluation memo (so a
  # shared/diamond prerequisite is evaluated once, not re-walked exponentially) and a
  # visited set for cycle detection. Returns `{{:ok, boolean} | :cycle, memo}`. Cycle
  # results are never memoized so they stay path-correct.
  defp resolve(conf, flag_name, eval_opts, visited, memo) do
    cond do
      flag_name in visited ->
        {:cycle, memo}

      Map.has_key?(memo, flag_name) ->
        {{:ok, Map.fetch!(memo, flag_name)}, memo}

      true ->
        case Store.lookup(conf, flag_name) do
          {:ok, flag} ->
            case prereqs_status(conf, flag, eval_opts, [flag_name | visited], memo) do
              {:cycle, m} ->
                {:cycle, m}

              {:not_met, m} ->
                {{:ok, false}, Map.put(m, flag_name, false)}

              {:ok, m} ->
                enabled = Flag.enabled?(expand_segments(conf, flag), eval_opts)
                {{:ok, enabled}, Map.put(m, flag_name, enabled)}
            end

          _ ->
            {{:ok, false}, Map.put(memo, flag_name, false)}
        end
    end
  end

  defp lookup_failed(flag_name, error, default) do
    Logger.warning("[Bandera] store lookup for #{inspect(flag_name)} failed: #{inspect(error)}")
    default
  end

  defp maybe_auto_create(conf, flag_name) do
    if auto_create?(conf) and not String.starts_with?(to_string(flag_name), @segment_prefix) do
      case Store.put(conf, flag_name, Gate.new(:boolean, false)) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Bandera] auto_create put for #{inspect(flag_name)} failed: #{inspect(reason)}"
          )
      end
    end
  end

  # The default instance has always read `config :bandera, auto_create:` live (no
  # reload needed); keep that unless it was started with an explicit
  # `auto_create:` option. Named instances use their config.
  defp auto_create?(%Config{name: Bandera, start_opts: start_opts} = conf) do
    if Keyword.has_key?(start_opts, :auto_create),
      do: conf.auto_create,
      else: Application.get_env(:bandera, :auto_create, true)
  end

  defp auto_create?(%Config{auto_create: auto_create}), do: auto_create
end
