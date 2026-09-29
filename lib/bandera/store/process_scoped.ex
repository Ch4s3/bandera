if Code.ensure_loaded?(NimbleOwnership) do
  defmodule Bandera.Store.ProcessScoped do
    @moduledoc """
    Process-scoped overlay store for tests, backed by `NimbleOwnership`.

    Flag state is owned per-process and resolved through the `[self() | $callers]`
    chain (the same mechanism Mox and `Ecto.Adapters.SQL.Sandbox` use), so spawned
    `Task`s and LiveView processes inherit their test's overrides. A flag with no
    override resolves to an empty (disabled) flag — overrides overlay on that static
    default; no global mutable store is consulted, so `async: true` tests never bleed
    into each other and flag writes never touch a database or fire notifications.

    One NimbleOwnership server backs every instance that uses this store; overrides
    are scoped per instance (keyed by the instance's `name`), so a named instance's
    overrides are invisible to another instance in the same test process.

    Configure it as the active store in the test environment:

        # config/test.exs
        config :bandera, store: Bandera.Store.ProcessScoped

    and, for a named instance:

        config :my_app, MyApp.Flags, store: Bandera.Store.ProcessScoped

    Either way, start the ownership server once in `test/test_helper.exs` via
    `Bandera.Test.start/0`. Per-test cleanup is automatic — NimbleOwnership monitors
    the owning process and drops its state when the test process exits.
    """

    @behaviour Bandera.Store

    alias Bandera.Config
    alias Bandera.Flag
    alias Bandera.Gate

    @ownership __MODULE__

    @doc "Start the backing NimbleOwnership server (named after this module)."
    @spec start_link(keyword) :: GenServer.on_start()
    def start_link(opts \\ []) do
      NimbleOwnership.start_link(Keyword.put_new(opts, :name, @ownership))
    end

    @impl Bandera.Store
    def lookup(%Config{} = conf, flag_name) do
      gates = conf |> current_flags() |> Map.get(flag_name, %{}) |> Map.values()
      {:ok, Flag.new(flag_name, gates)}
    end

    @impl Bandera.Store
    def put(%Config{} = conf, flag_name, %Gate{} = gate) do
      update(conf, fn flags ->
        gates = flags |> Map.get(flag_name, %{}) |> Map.put(Gate.id(gate), gate)
        Map.put(flags, flag_name, gates)
      end)

      lookup(conf, flag_name)
    end

    @impl Bandera.Store
    def delete(%Config{} = conf, flag_name, %Gate{} = gate) do
      update(conf, fn flags ->
        gates = flags |> Map.get(flag_name, %{}) |> Map.delete(Gate.id(gate))

        if map_size(gates) == 0 do
          Map.delete(flags, flag_name)
        else
          Map.put(flags, flag_name, gates)
        end
      end)

      lookup(conf, flag_name)
    end

    @impl Bandera.Store
    def delete(%Config{} = conf, flag_name) do
      update(conf, fn flags -> Map.delete(flags, flag_name) end)
      {:ok, Flag.new(flag_name, [])}
    end

    def delete(flag_name, %Gate{} = gate) when is_atom(flag_name),
      do: delete(Config.get(), flag_name, gate)

    @impl Bandera.Store
    def all_flags(%Config{} = conf) do
      flags =
        conf
        |> current_flags()
        |> Enum.map(fn {name, gates} -> Flag.new(name, Map.values(gates)) end)

      {:ok, flags}
    end

    @impl Bandera.Store
    def all_flag_names(%Config{} = conf) do
      {:ok, conf |> current_flags() |> Map.keys()}
    end

    # ---- NimbleOwnership plumbing ----

    # One key per instance, so overrides for one instance never leak into another
    # sharing the same ownership server (and the same owning process). The default
    # instance keeps the historical `:flags` key, so existing
    # `NimbleOwnership.allow(Bandera.Store.ProcessScoped, owner, pid, :flags)` calls
    # still share its overrides.
    defp key(%Config{name: Bandera}), do: :flags
    defp key(%Config{name: name}), do: {:flags, name}

    defp current_flags(conf) do
      callers = [self() | Process.get(:"$callers", [])]
      key = key(conf)

      case NimbleOwnership.fetch_owner(@ownership, callers, key) do
        {tag, owner} when tag in [:ok, :shared_owner] ->
          @ownership |> NimbleOwnership.get_owned(owner, %{}) |> Map.get(key, %{})

        :error ->
          %{}
      end
    end

    defp update(conf, fun) do
      key = key(conf)

      case NimbleOwnership.get_and_update(@ownership, self(), key, fn
             nil -> {nil, fun.(%{})}
             flags -> {nil, fun.(flags)}
           end) do
        {:ok, _} -> :ok
        {:error, error} -> raise "Bandera.Store.ProcessScoped write failed: #{inspect(error)}"
      end
    end

    # ---- default-instance forms (backward compatibility) ----
    # The pre-instance arities, acting on the default instance (the
    # `delete(flag_name, gate)` form sits with the `delete/2` callback above).

    @doc false

    @spec lookup(atom) :: {:ok, Bandera.Flag.t()} | {:error, term}
    def lookup(flag_name) when is_atom(flag_name), do: lookup(Config.get(), flag_name)

    @doc false

    @spec put(atom, Bandera.Gate.t()) :: {:ok, Bandera.Flag.t()} | {:error, term}
    def put(flag_name, %Gate{} = gate) when is_atom(flag_name),
      do: put(Config.get(), flag_name, gate)

    @doc false

    @spec delete(atom) :: {:ok, Bandera.Flag.t()} | {:error, term}
    def delete(flag_name) when is_atom(flag_name), do: delete(Config.get(), flag_name)

    @doc false

    @spec all_flags() :: {:ok, [Bandera.Flag.t()]} | {:error, term}
    def all_flags, do: all_flags(Config.get())

    @doc false

    @spec all_flag_names() :: {:ok, [atom]} | {:error, term}
    def all_flag_names, do: all_flag_names(Config.get())
  end
end
