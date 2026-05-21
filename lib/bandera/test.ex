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
    for unqualified use. The remaining helpers — `put_flag/2,3`, `clear/1`, and
    `reset/0` — are called fully qualified, e.g. `Bandera.Test.reset()`.

    Consumers must add `{:nimble_ownership, "~> 1.0", only: :test}` to their deps.
    """

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
    def put_flag(flag_name, true), do: drop(Bandera.enable(flag_name))
    def put_flag(flag_name, false), do: drop(Bandera.disable(flag_name))

    @doc "Set a flag's boolean value for a specific actor in the current process."
    @spec put_flag(atom, boolean, term) :: :ok
    def put_flag(flag_name, true, actor), do: drop(Bandera.enable(flag_name, for_actor: actor))
    def put_flag(flag_name, false, actor), do: drop(Bandera.disable(flag_name, for_actor: actor))

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
    def clear(flag_name), do: drop(Bandera.clear(flag_name))

    @doc "Clear ALL of the current process's flag overrides."
    @spec reset() :: :ok
    def reset do
      NimbleOwnership.cleanup_owner(ProcessScoped, self())
      :ok
    end

    defp drop({:ok, _}), do: :ok
    defp drop(:ok), do: :ok

    defp drop({:error, reason}),
      do: raise("Bandera.Test: unexpected store error: #{inspect(reason)}")

    @doc false
    defmacro __using__(_opts) do
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
    end
  end
end
