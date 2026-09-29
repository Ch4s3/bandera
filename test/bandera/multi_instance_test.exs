defmodule Bandera.MultiInstanceTest do
  # async: false — instances register global names, and these tests assert the
  # default instance's processes are NOT running (so any code path that silently
  # falls back to the default instance crashes instead of passing by accident).
  use ExUnit.Case, async: false

  alias Bandera.Config
  alias Bandera.Store.Persistent.Memory

  @otp_app :bandera_multi_instance_test

  defmodule Flags do
    use Bandera, otp_app: :bandera_multi_instance_test
  end

  defmodule BareFlags do
    use Bandera
  end

  defmodule DefaultedFlags do
    use Bandera,
      otp_app: :bandera_multi_instance_test,
      defaults: [cache: [ttl: 11, enabled: false], auto_create: false]
  end

  setup do
    # The default instance is not started in the test env (start_on_boot: false);
    # make that an explicit precondition of every test here.
    refute Process.whereis(Bandera.Store.Cache)
    refute Process.whereis(Memory)
    :ok
  end

  defp start_instance(name, opts \\ []),
    do: start_supervised!({Bandera, Keyword.put(opts, :name, name)})

  describe "isolation between instances" do
    setup do
      start_instance(:inst_a)
      start_instance(:inst_b)
      :ok
    end

    test "the same flag name holds independent state per instance" do
      assert {:ok, true} = Bandera.enable(:checkout, instance: :inst_a)

      assert Bandera.enabled?(:checkout, instance: :inst_a)
      refute Bandera.enabled?(:checkout, instance: :inst_b)

      assert {:ok, true} = Bandera.enable(:checkout, for_actor: "u1", instance: :inst_b)
      assert Bandera.enabled?(:checkout, for: "u1", instance: :inst_b)
      refute Bandera.enabled?(:checkout, for: "u2", instance: :inst_b)
      assert Bandera.enabled?(:checkout, for: "u2", instance: :inst_a)
    end

    test "introspection only sees the instance's own flags" do
      {:ok, _} = Bandera.enable(:only_a, instance: :inst_a)
      {:ok, _} = Bandera.enable(:only_b, instance: :inst_b)

      assert {:ok, [:only_a]} = Bandera.all_flag_names(instance: :inst_a)
      assert {:ok, [%Bandera.Flag{name: :only_b}]} = Bandera.all_flags(instance: :inst_b)
      assert {:ok, %Bandera.Flag{gates: []}} = Bandera.get_flag(:only_a, instance: :inst_b)
    end

    test "clear, variants, segments, and prerequisites resolve within the instance" do
      {:ok, _} = Bandera.enable(:parent, instance: :inst_a)
      {:ok, _} = Bandera.enable(:child, requires: :parent, instance: :inst_a)
      {:ok, _} = Bandera.enable(:child, requires: :parent, instance: :inst_b)
      {:ok, _} = Bandera.enable(:child, instance: :inst_a)
      {:ok, _} = Bandera.enable(:child, instance: :inst_b)

      assert Bandera.enabled?(:child, instance: :inst_a)
      # :parent is only enabled in inst_a, so inst_b's prerequisite is not met.
      refute Bandera.enabled?(:child, instance: :inst_b)

      {:ok, _} = Bandera.put_segment(:pro, [{"plan", :eq, "pro"}], instance: :inst_a)
      {:ok, _} = Bandera.enable(:seg, for_segment: "pro", instance: :inst_a)
      {:ok, _} = Bandera.enable(:seg, for_segment: "pro", instance: :inst_b)
      assert Bandera.enabled?(:seg, context: %{"plan" => "pro"}, instance: :inst_a)
      refute Bandera.enabled?(:seg, context: %{"plan" => "pro"}, instance: :inst_b)

      {:ok, _} = Bandera.put_variants(:ab, %{"x" => 1}, instance: :inst_a)
      assert Bandera.variant(:ab, for: %{id: 1}, instance: :inst_a) == "x"
      assert Bandera.variant(:ab, for: %{id: 1}, instance: :inst_b, default: :none) == :none

      assert :ok = Bandera.clear(:parent, instance: :inst_a)
      refute Bandera.enabled?(:child, instance: :inst_a)
    end

    test "each instance has its own cache table" do
      {:ok, _} = Bandera.enable(:cached, instance: :inst_a)
      a = Config.get(:inst_a)
      b = Config.get(:inst_b)

      assert a.cache_table != b.cache_table
      assert {:ok, %Bandera.Flag{name: :cached}} = Bandera.Store.Cache.get(a, :cached)
      assert {:miss, :not_found} = Bandera.Store.Cache.get(b, :cached)
    end

    test "auto_create writes into the evaluating instance only" do
      refute Bandera.enabled?(:auto, instance: :inst_a)
      assert {:ok, [:auto]} = Bandera.all_flag_names(instance: :inst_a)
      assert {:ok, []} = Bandera.all_flag_names(instance: :inst_b)
    end

    test "telemetry events carry the instance name" do
      test_pid = self()
      handler = {__MODULE__, make_ref()}

      :telemetry.attach_many(
        handler,
        [
          [:bandera, :enabled?],
          [:bandera, :enable, :stop],
          [:bandera, :persistence, :put, :stop]
        ],
        fn event, _m, meta, _ -> send(test_pid, {event, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, _} = Bandera.enable(:t, instance: :inst_b, by: "ops")
      _ = Bandera.enabled?(:t, instance: :inst_b)

      assert_received {[:bandera, :enable, :stop], %{instance: :inst_b, options: [by: "ops"]}}
      assert_received {[:bandera, :persistence, :put, :stop], %{instance: :inst_b}}
      assert_received {[:bandera, :enabled?], %{instance: :inst_b}}
    end

    test "audit events carry the instance name" do
      test_pid = self()
      handler = {__MODULE__, make_ref()}
      :ok = Bandera.Audit.attach(handler, &send(test_pid, {:audit, &1}))
      on_exit(fn -> Bandera.Audit.detach(handler) end)

      {:ok, _} = Bandera.enable(:audited, instance: :inst_a)

      assert_received {:audit, %Bandera.Audit.Event{instance: :inst_a, flag_name: :audited}}
    end

    test "notifications publish through the writing instance's own config" do
      Application.put_env(:bandera, :test_notifier_pid, self())
      on_exit(fn -> Application.delete_env(:bandera, :test_notifier_pid) end)

      start_instance(:inst_notify,
        cache_bust_notifications: [enabled: true, adapter: Bandera.TestNotifier]
      )

      {:ok, _} = Bandera.enable(:quiet, instance: :inst_a)
      refute_received {:published, :quiet}

      {:ok, _} = Bandera.enable(:loud, instance: :inst_notify)
      assert_received {:published, :loud}
    end
  end

  describe "instance lifecycle" do
    test "an unknown instance raises instead of falling back to the default" do
      assert_raise ArgumentError, ~r/unknown Bandera instance :nope/, fn ->
        Bandera.enabled?(:x, instance: :nope)
      end
    end

    test "a stopped instance raises on use" do
      start_instance(:stopping)
      assert {:ok, true} = Bandera.enable(:x, instance: :stopping)
      :ok = stop_supervised!(:stopping)

      assert_raise ArgumentError, ~r/unknown Bandera instance :stopping/, fn ->
        Bandera.enabled?(:x, instance: :stopping)
      end
    end

    test "starting the same instance name twice is refused" do
      start_instance(:dup)
      assert {:error, {:already_started, _}} = Bandera.start_link(name: :dup)
    end

    test "invalid options and names are rejected" do
      assert_raise ArgumentError, ~r/unknown keys \[:persistance\]/, fn ->
        Config.new(name: :typo, persistance: [])
      end

      assert_raise ArgumentError, ~r/must be an atom/, fn -> Config.new(name: "flags") end
      assert_raise ArgumentError, ~r/must be an atom/, fn -> Config.new(name: nil) end
    end

    test "named instances get scoped resource names; the default keeps the historical ones" do
      default = Config.new()
      named = Config.new(name: MyApp.Flags)

      assert default.cache_table == Bandera.Store.Cache
      assert default.memory_table == Memory
      assert default.usage_server == Bandera.Usage
      assert default.namespace == "bandera"

      assert named.cache_table == MyApp.Flags.Bandera.Store.Cache
      assert named.memory_table == MyApp.Flags.Bandera.Store.Persistent.Memory
      assert named.usage_server == MyApp.Flags.Bandera.Usage
      assert named.namespace == "bandera:{MyApp.Flags}"
      assert Config.new(name: :plain).namespace == "bandera:{plain}"
    end

    test "the registrar re-claims storage after a crash (dead-owner race)" do
      sup =
        start_instance(:crashy,
          persistence: [adapter: Bandera.ClaimingAdapter, storage_key: :crashy_storage]
        )

      [{registrar, _}] = Registry.lookup(Bandera.Registry, {:storage, :crashy_storage})
      Process.exit(registrar, :kill)

      assert wait_until(fn ->
               match?(
                 [{pid, :crashy}] when pid != registrar,
                 Registry.lookup(Bandera.Registry, {:storage, :crashy_storage})
               )
             end)

      assert Process.alive?(sup)
      assert {:ok, _} = Bandera.enable(:still_works, instance: :crashy)
    end
  end

  describe "the default instance started as an instance" do
    setup do
      on_exit(fn ->
        Application.delete_env(:bandera, :persistence)
        Bandera.reload_config()
      end)

      :ok
    end

    test "runs under its historical names, and publishes then erases its config" do
      start_supervised!(Bandera)

      assert Process.whereis(Bandera.Store.Cache)
      assert Process.whereis(Memory)
      assert %Config{name: Bandera} = :persistent_term.get({Config, Bandera}, nil)
      assert {:ok, true} = Bandera.enable(:boot_default)
      assert Bandera.enabled?(:boot_default)

      :ok = stop_supervised!(Bandera)
      assert :persistent_term.get({Config, Bandera}, :erased) == :erased
      # ...and is lazily reseeded from application env on next use.
      assert %Config{name: Bandera} = Config.get()
    end

    test "starts with the Ecto adapter even before a repo is configured" do
      Application.put_env(:bandera, :persistence, adapter: Bandera.Store.Persistent.Ecto)
      Bandera.reload_config()

      start_supervised!(Bandera)
      start_supervised!(Bandera.Usage)
      refute Bandera.Usage.ready?()
    end

    test "an explicit auto_create: false start option is honored" do
      start_supervised!({Bandera, auto_create: false})

      refute Bandera.enabled?(:not_auto_created)
      assert {:ok, []} = Bandera.all_flag_names()
    end

    test "its config still supports map-style access (the old snapshot was a map)" do
      assert Config.snapshot()[:store] == Bandera.Store.TwoLevel
      assert Config.get()[:name] == Bandera
    end
  end

  describe "storage claims" do
    test "a second instance on the same storage refuses to start" do
      opts = [persistence: [adapter: Bandera.ClaimingAdapter, storage_key: :shared]]
      start_instance(:owner, opts)

      assert {:error,
              {{:shutdown, {:failed_to_start_child, Bandera.Instance.Registrar, reason}}, _}} =
               start_supervised({Bandera, Keyword.put(opts, :name, :intruder)})

      assert reason == {:storage_conflict, :shared, :owner}
      assert_raise ArgumentError, fn -> Config.get(:intruder) end
    end

    test "distinct storage coexists, and a claim is released when its instance stops" do
      start_instance(:first, persistence: [adapter: Bandera.ClaimingAdapter, storage_key: :k1])
      start_instance(:second, persistence: [adapter: Bandera.ClaimingAdapter, storage_key: :k2])

      :ok = stop_supervised!(:first)
      assert wait_until(fn -> Registry.lookup(Bandera.Registry, {:storage, :k1}) == [] end)

      start_instance(:third, persistence: [adapter: Bandera.ClaimingAdapter, storage_key: :k1])
    end

    test "stores other than TwoLevel claim nothing" do
      opts = [
        store: Bandera.FailingStore,
        persistence: [adapter: Bandera.ClaimingAdapter, storage_key: :unused]
      ]

      start_instance(:no_claim_1, opts)
      start_instance(:no_claim_2, opts)
    end
  end

  describe "use Bandera facade" do
    setup do
      on_exit(fn -> Application.delete_env(@otp_app, Flags) end)
      :ok
    end

    test "is bound to its own instance and reads config from its otp_app at start" do
      Application.put_env(@otp_app, Flags, cache: [ttl: 42])
      start_supervised!(Flags)
      start_instance(:other)

      assert Config.get(Flags).cache_ttl == 42
      assert {:ok, true} = Flags.enable(:facade_flag)
      assert Flags.enabled?(:facade_flag)
      refute Bandera.enabled?(:facade_flag, instance: :other)
      assert {:ok, [:facade_flag]} = Flags.all_flag_names()
      assert {:ok, %Bandera.Flag{name: :facade_flag}} = Flags.get_flag(:facade_flag)
      assert :ok = Flags.clear(:facade_flag)
      refute Flags.enabled?(:facade_flag)
    end

    test "child_spec options override otp_app config (one level deep); the facade's name always wins" do
      Application.put_env(@otp_app, Flags, cache: [ttl: 42, enabled: false])
      start_supervised!({Flags, cache: [ttl: 7], name: :ignored})

      assert Config.get(Flags).cache_ttl == 7
      # the explicit `cache:` refines the env's `cache:` instead of replacing it
      refute Config.get(Flags).cache_enabled?
      assert_raise ArgumentError, fn -> Config.get(:ignored) end
    end

    test "reload_config/0 re-reads the otp_app config" do
      Application.put_env(@otp_app, Flags, cache: [ttl: 42])
      start_supervised!(Flags)

      Application.put_env(@otp_app, Flags, cache: [ttl: 99])
      assert :ok = Flags.reload_config()
      assert Config.get(Flags).cache_ttl == 99
    end

    test "a restarted registrar republishes the current (reloaded) settings" do
      Application.put_env(@otp_app, Flags, cache: [ttl: 42])
      start_supervised!(Flags)
      Application.put_env(@otp_app, Flags, cache: [ttl: 99])
      :ok = Flags.reload_config()

      registrar = registrar_pid(Flags)
      Process.exit(registrar, :kill)
      assert wait_until(fn -> registrar_pid(Flags) not in [nil, registrar] end)

      assert Config.get(Flags).cache_ttl == 99
    end

    test "the instance passed to a facade call cannot be overridden" do
      start_supervised!(Flags)
      start_instance(:other)

      {:ok, _} = Flags.enable(:pinned, instance: :other)
      assert Flags.enabled?(:pinned)
      refute Bandera.enabled?(:pinned, instance: :other)
    end

    test "works without an otp_app" do
      start_supervised!({BareFlags, cache: [ttl: 5]})
      assert Config.get(BareFlags).cache_ttl == 5
      assert {:ok, true} = BareFlags.enable(:bare)
    end

    test "defaults are the lowest layer; env and child options refine them one level deep" do
      on_exit(fn -> Application.delete_env(@otp_app, DefaultedFlags) end)

      assert DefaultedFlags.__bandera_defaults__() ==
               [cache: [ttl: 11, enabled: false], auto_create: false]

      start_supervised!(DefaultedFlags)
      conf = Config.get(DefaultedFlags)
      assert {conf.cache_ttl, conf.cache_enabled?, conf.auto_create} == {11, false, false}

      # env overrides the defaults' ttl but keeps their `enabled: false`
      Application.put_env(@otp_app, DefaultedFlags, cache: [ttl: 22])
      :ok = DefaultedFlags.reload_config()
      conf = Config.get(DefaultedFlags)
      assert {conf.cache_ttl, conf.cache_enabled?, conf.auto_create} == {22, false, false}

      stop_supervised!(DefaultedFlags)
      start_supervised!({DefaultedFlags, cache: [ttl: 33]})
      conf = Config.get(DefaultedFlags)
      assert {conf.cache_ttl, conf.cache_enabled?} == {33, false}
    end

    test "defaults with unknown settings are rejected" do
      assert_raise ArgumentError, ~r/unknown keys \[:persistance\]/, fn ->
        Config.new(name: :bad_defaults, defaults: [persistance: []])
      end
    end
  end

  describe "Bandera.Usage per instance" do
    setup do
      start_instance(:tracked)
      start_instance(:untracked)
      start_supervised!({Bandera.Usage, instance: :tracked})
      :ok
    end

    test "records only its own instance's evaluations" do
      _ = Bandera.enabled?(:seen, instance: :untracked)
      refute Bandera.Usage.last_evaluated(:tracked, :seen)

      _ = Bandera.enabled?(:seen, instance: :tracked)
      assert %DateTime{} = Bandera.Usage.last_evaluated(:tracked, :seen)
      assert %DateTime{} = Bandera.Usage.last_evaluated(Config.get(:tracked), :seen)
    end

    test "is addressed by instance, not the default tracker" do
      assert Bandera.Usage.ready?(:tracked)
      assert :ok = Bandera.Usage.flush(:tracked)
      refute Process.whereis(Bandera.Usage)
    end

    test "stale_flags/1 is scoped to the instance" do
      {:ok, _} = Bandera.enable(:fresh, instance: :tracked)
      {:ok, _} = Bandera.enable(:dusty, instance: :tracked)
      _ = Bandera.enabled?(:fresh, instance: :tracked)

      assert Bandera.stale_flags(instance: :tracked) == [:dusty]
      # No tracker for :untracked, so every flag reads as stale there.
      {:ok, _} = Bandera.enable(:fresh, instance: :untracked)
      assert Bandera.stale_flags(instance: :untracked) == [:fresh]
    end
  end

  describe "legacy (config-less) extension modules" do
    setup do
      Application.put_env(:bandera, :legacy_test_pid, self())
      on_exit(fn -> Application.delete_env(:bandera, :legacy_test_pid) end)
      :ok
    end

    test "are detected when the config is built" do
      conf =
        Config.new(
          name: :legacy_detect,
          store: Bandera.LegacyStore,
          persistence: [adapter: Bandera.LegacyPersistence],
          cache_bust_notifications: [enabled: true, adapter: Bandera.LegacyNotifier]
        )

      assert conf.store_legacy?
      assert conf.persistence_legacy?
      assert conf.notifications_legacy?

      refute Config.new(name: :modern).store_legacy?
      refute Config.new(name: :modern).persistence_legacy?
    end

    test "a legacy store keeps working through the public API" do
      start_instance(:legacy_store, store: Bandera.LegacyStore)

      assert Bandera.enabled?(:anything, instance: :legacy_store)
      assert {:ok, [:legacy_flag]} = Bandera.all_flag_names(instance: :legacy_store)
      {:ok, _} = Bandera.enable(:w, instance: :legacy_store)
      assert_received {:legacy_store, :put, :w, %Bandera.Gate{type: :boolean}}
      :ok = Bandera.clear(:w, instance: :legacy_store)
      assert_received {:legacy_store, :delete, :w}
    end

    test "a legacy persistence adapter and notifier keep working under TwoLevel" do
      start_supervised!(Bandera.LegacyPersistence)

      start_instance(:legacy_persist,
        persistence: [adapter: Bandera.LegacyPersistence],
        cache_bust_notifications: [enabled: true, adapter: Bandera.LegacyNotifier]
      )

      {:ok, true} = Bandera.enable(:lp, instance: :legacy_persist)
      assert_received {:legacy_published, :lp}
      assert Bandera.enabled?(:lp, instance: :legacy_persist)
      assert {:ok, %Bandera.Flag{gates: [_]}} = Bandera.LegacyPersistence.get(:lp)
      assert {:ok, [:lp]} = Bandera.all_flag_names(instance: :legacy_persist)
    end
  end

  defp registrar_pid(instance) do
    instance
    |> Config.get()
    |> Map.fetch!(:supervisor)
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {Bandera.Instance.Registrar, pid, _, _} when is_pid(pid) -> pid
      _ -> nil
    end)
  end

  defp wait_until(fun, timeout \\ 1_000) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(10) && wait_until(fun, timeout - 10)
    end
  end
end
