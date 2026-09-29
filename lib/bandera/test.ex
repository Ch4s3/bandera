if Code.ensure_loaded?(NimbleOwnership) do
  defmodule Bandera.Test do
    @moduledoc """
    Test helpers for toggling Bandera flags with per-test, async-safe isolation.

    Backed by `Bandera.Store.ProcessScoped` (NimbleOwnership). Setup:

        # config/test.exs
        config :bandera, store: Bandera.Store.ProcessScoped

        # test/test_helper.exs
        Bandera.Test.start()

        # a test module
        defmodule MyTest do
          use ExUnit.Case, async: true
          use Bandera.Test

          @tag feature_flags: [my_flag: true]
          test "feature on" do
            assert Bandera.enabled?(:my_flag)
          end

          test "toggle in the body" do
            enable_flag(:other)
            assert Bandera.enabled?(:other)
          end
        end

    Overrides are scoped to the test process (and its `$callers`), so tests run
    `async: true` without bleeding into each other, and `enable_flag`/`disable_flag`
    never touch a database or fire notifications. Cleanup is automatic when the test
    process exits (NimbleOwnership monitors owners); `reset/0` clears overrides
    explicitly within a test if needed.

    The `use Bandera.Test` macro imports `enable_flag/1,2` and `disable_flag/1,2`
    for unqualified use. The remaining helpers — `put_flag/2,3,4`, `clear/1,2`, and
    `reset/0` — are called fully qualified, e.g. `Bandera.Test.reset()`.

    ## Testing a named instance

    A named instance can use `Bandera.Store.ProcessScoped` too — configure it in
    the test env just like the default instance:

        # config/test.exs
        config :my_app, MyApp.Flags, store: Bandera.Store.ProcessScoped

    still calling `Bandera.Test.start/0` once (one ownership server backs every
    instance; overrides are scoped per instance under the hood). Then either call
    the facade directly:

        MyApp.Flags.enable(:f)

    or bind the `enable_flag`/`disable_flag` helpers and the `@tag feature_flags`
    setup to that instance:

        use Bandera.Test, instance: MyApp.Flags

    Consumers must add `{:nimble_ownership, "~> 1.0", only: :test}` to their deps.
    """

    alias Bandera.Config
    alias Bandera.Store.ProcessScoped

    @doc """
    Start the NimbleOwnership server backing the process-scoped store.

    Idempotent — call once in `test/test_helper.exs`.
    """
    @spec start() :: :ok
    def start do
      case ProcessScoped.start_link() do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    @doc "Set a flag's boolean value for the current process (and its `$callers`)."
    @spec put_flag(atom, boolean) :: :ok
    def put_flag(flag_name, value), do: put_flag(flag_name, value, nil, [])

    @doc "Set a flag's boolean value for a specific actor in the current process."
    @spec put_flag(atom, boolean, term) :: :ok
    def put_flag(flag_name, value, actor), do: put_flag(flag_name, value, actor, [])

    @doc """
    Set a flag's boolean value for the current process, optionally scoped to `actor`.

    `actor` may be `nil` to target the plain boolean gate. Accepts `instance:` in
    `opts` (default the default instance).
    """
    @spec put_flag(atom, boolean, term, keyword) :: :ok
    def put_flag(flag_name, true, nil, opts), do: drop(Bandera.enable(flag_name, opts))
    def put_flag(flag_name, false, nil, opts), do: drop(Bandera.disable(flag_name, opts))

    def put_flag(flag_name, true, actor, opts),
      do: drop(Bandera.enable(flag_name, [{:for_actor, actor} | opts]))

    def put_flag(flag_name, false, actor, opts),
      do: drop(Bandera.disable(flag_name, [{:for_actor, actor} | opts]))

    @doc "Enable a flag for the current process."
    @spec enable_flag(atom) :: :ok
    def enable_flag(flag_name), do: put_flag(flag_name, true)

    @doc "Enable a flag for a specific actor in the current process."
    @spec enable_flag(atom, term) :: :ok
    def enable_flag(flag_name, actor), do: put_flag(flag_name, true, actor)

    @doc "Disable a flag for the current process."
    @spec disable_flag(atom) :: :ok
    def disable_flag(flag_name), do: put_flag(flag_name, false)

    @doc "Disable a flag for a specific actor in the current process."
    @spec disable_flag(atom, term) :: :ok
    def disable_flag(flag_name, actor), do: put_flag(flag_name, false, actor)

    @doc "Clear a single flag's overrides for the current process."
    @spec clear(atom) :: :ok
    def clear(flag_name), do: clear(flag_name, [])

    @doc "Clear a single flag's overrides for the current process, in `instance:` (opts)."
    @spec clear(atom, keyword) :: :ok
    def clear(flag_name, opts), do: drop(Bandera.clear(flag_name, opts))

    @doc """
    Clear ALL of the current process's flag overrides, across every instance.

    This is a single `NimbleOwnership.cleanup_owner/2` call against the shared
    ownership server, so it drops the calling process's overrides for the default
    instance and every named instance that also uses `Bandera.Store.ProcessScoped`.
    """
    @spec reset() :: :ok
    def reset do
      NimbleOwnership.cleanup_owner(ProcessScoped, self())
      :ok
    end

    defp drop({:ok, _}), do: :ok
    defp drop(:ok), do: :ok

    defp drop({:error, reason}),
      do: raise("Bandera.Test: unexpected store error: #{inspect(reason)}")

    @doc """
    Sets up `@tag feature_flags` and, without `instance:`, imports `enable_flag/1,2`
    and `disable_flag/1,2` for unqualified use against the default instance.

    Pass `instance: MyApp.Flags` to bind `@tag feature_flags` (and to define private
    `enable_flag/1,2` and `disable_flag/1,2` helpers, since an import can't be bound
    to a specific instance) to that instance instead.
    """
    defmacro __using__(opts) do
      instance = Keyword.get(opts, :instance, Config.default_instance())

      if instance == Config.default_instance() do
        quote do
          import Bandera.Test,
            only: [enable_flag: 1, enable_flag: 2, disable_flag: 1, disable_flag: 2]

          setup context do
            for {flag_name, value} <- Map.get(context, :feature_flags, []) do
              Bandera.Test.put_flag(flag_name, value)
            end

            :ok
          end
        end
      else
        quote bind_quoted: [instance: instance] do
          # A module attribute, not the bound variable, because `def`/`defp` bodies
          # compile in their own scope and can't see variables from the caller.
          @bandera_test_instance instance

          defp enable_flag(flag_name),
            do: Bandera.Test.put_flag(flag_name, true, nil, instance: @bandera_test_instance)

          defp enable_flag(flag_name, actor),
            do: Bandera.Test.put_flag(flag_name, true, actor, instance: @bandera_test_instance)

          defp disable_flag(flag_name),
            do: Bandera.Test.put_flag(flag_name, false, nil, instance: @bandera_test_instance)

          defp disable_flag(flag_name, actor),
            do: Bandera.Test.put_flag(flag_name, false, actor, instance: @bandera_test_instance)

          setup context do
            for {flag_name, value} <- Map.get(context, :feature_flags, []) do
              Bandera.Test.put_flag(flag_name, value, nil, instance: @bandera_test_instance)
            end

            :ok
          end
        end
      end
    end
  end
end
