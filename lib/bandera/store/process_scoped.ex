defmodule Bandera.Store.ProcessScoped do
  @moduledoc """
  Process-scoped overlay store for tests, backed by `NimbleOwnership`.

  Flag state is owned per-process and resolved through the `[self() | $callers]`
  chain (the same mechanism Mox and `Ecto.Adapters.SQL.Sandbox` use), so spawned
  `Task`s and LiveView processes inherit their test's overrides. A flag with no
  override resolves to an empty (disabled) flag — overrides overlay on that static
  default; no global mutable store is consulted, so `async: true` tests never bleed
  into each other and flag writes never touch a database or fire notifications.

  Configure it as the active store in the test environment:

      # config/test.exs
      config :bandera, store: Bandera.Store.ProcessScoped

  and start the ownership server once in `test/test_helper.exs` via
  `Bandera.Test.start/0`. Per-test cleanup is automatic — NimbleOwnership monitors
  the owning process and drops its state when the test process exits.
  """

  @behaviour Bandera.Store

  alias Bandera.Flag
  alias Bandera.Gate

  @ownership __MODULE__
  @key :flags

  @doc "Start the backing NimbleOwnership server (named after this module)."
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts \\ []) do
    NimbleOwnership.start_link(Keyword.put_new(opts, :name, @ownership))
  end

  @impl Bandera.Store
  def lookup(flag_name) do
    gates = current_flags() |> Map.get(flag_name, %{}) |> Map.values()
    {:ok, Flag.new(flag_name, gates)}
  end

  @impl Bandera.Store
  def put(flag_name, %Gate{} = gate) do
    update(fn flags ->
      gates = flags |> Map.get(flag_name, %{}) |> Map.put(Gate.id(gate), gate)
      Map.put(flags, flag_name, gates)
    end)

    lookup(flag_name)
  end

  @impl Bandera.Store
  def delete(flag_name, %Gate{} = gate) do
    update(fn flags ->
      gates = flags |> Map.get(flag_name, %{}) |> Map.delete(Gate.id(gate))

      if map_size(gates) == 0 do
        Map.delete(flags, flag_name)
      else
        Map.put(flags, flag_name, gates)
      end
    end)

    lookup(flag_name)
  end

  @impl Bandera.Store
  def delete(flag_name) do
    update(fn flags -> Map.delete(flags, flag_name) end)
    {:ok, Flag.new(flag_name, [])}
  end

  @impl Bandera.Store
  def all_flags do
    flags = Enum.map(current_flags(), fn {name, gates} -> Flag.new(name, Map.values(gates)) end)
    {:ok, flags}
  end

  @impl Bandera.Store
  def all_flag_names do
    {:ok, Map.keys(current_flags())}
  end

  # ---- NimbleOwnership plumbing ----

  defp current_flags do
    callers = [self() | Process.get(:"$callers", [])]

    case NimbleOwnership.fetch_owner(@ownership, callers, @key) do
      {tag, owner} when tag in [:ok, :shared_owner] ->
        @ownership |> NimbleOwnership.get_owned(owner, %{}) |> Map.get(@key, %{})

      :error ->
        %{}
    end
  end

  defp update(fun) do
    NimbleOwnership.get_and_update(@ownership, self(), @key, fn
      nil -> {:ok, fun.(%{})}
      flags -> {:ok, fun.(flags)}
    end)

    :ok
  end
end
