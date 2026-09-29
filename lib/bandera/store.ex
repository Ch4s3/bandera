defmodule Bandera.Store do
  @moduledoc """
  Behaviour for the active store the public API talks to.

  The concrete store is selected at RUNTIME, per instance, via `Bandera.Config`
  (default `Bandera.Store.TwoLevel`). `lookup/2` may add caching; writes go to the
  persistent layer. Every callback receives the calling instance's
  `%Bandera.Config{}` first, so one store module can serve several instances.

  ## Legacy (config-less) stores

  Stores written before instances existed implement the same callbacks without the
  leading config argument (`lookup/1`, `put/2`, ...). They keep working: Bandera
  detects them when the config is built and calls the old arities. Such a store
  cannot tell instances apart, so give every instance that uses it its own store
  module, or migrate it to the config-first callbacks.
  """

  alias Bandera.Config
  alias Bandera.Flag
  alias Bandera.Gate

  @doc "Reads a flag by name (may serve from cache). Returns `{:ok, flag}` or `{:error, reason}`."
  @callback lookup(Config.t(), flag_name :: atom) :: {:ok, Flag.t()} | {:error, term}

  @doc "Writes `gate` onto the flag and returns the updated flag (or `{:error, reason}`)."
  @callback put(Config.t(), flag_name :: atom, gate :: Gate.t()) ::
              {:ok, Flag.t()} | {:error, term}

  @doc "Removes a single `gate` from the flag and returns the updated flag (or `{:error, reason}`)."
  @callback delete(Config.t(), flag_name :: atom, gate :: Gate.t()) ::
              {:ok, Flag.t()} | {:error, term}

  @doc "Removes the entire flag and returns the resulting (empty) flag (or `{:error, reason}`)."
  @callback delete(Config.t(), flag_name :: atom) :: {:ok, Flag.t()} | {:error, term}

  @doc "Returns `{:ok, flags}` with every stored flag, or `{:error, reason}`."
  @callback all_flags(Config.t()) :: {:ok, [Flag.t()]} | {:error, term}

  @doc "Returns `{:ok, names}` with every stored flag name, or `{:error, reason}`."
  @callback all_flag_names(Config.t()) :: {:ok, [atom]} | {:error, term}

  @doc "The runtime-selected store module of the default instance."
  @spec active() :: module
  def active, do: Config.get().store

  # ---- dispatch (instance-aware or legacy) ----

  @doc false
  @spec lookup(Config.t(), atom) :: {:ok, Flag.t()} | {:error, term}
  def lookup(%Config{store_legacy?: false, store: store} = conf, flag_name),
    do: store.lookup(conf, flag_name)

  def lookup(%Config{store: store}, flag_name), do: store.lookup(flag_name)

  @doc false
  @spec put(Config.t(), atom, Gate.t()) :: {:ok, Flag.t()} | {:error, term}
  def put(%Config{store_legacy?: false, store: store} = conf, flag_name, gate),
    do: store.put(conf, flag_name, gate)

  def put(%Config{store: store}, flag_name, gate), do: store.put(flag_name, gate)

  @doc false
  @spec delete(Config.t(), atom, Gate.t()) :: {:ok, Flag.t()} | {:error, term}
  def delete(%Config{store_legacy?: false, store: store} = conf, flag_name, gate),
    do: store.delete(conf, flag_name, gate)

  def delete(%Config{store: store}, flag_name, gate), do: store.delete(flag_name, gate)

  @doc false
  @spec delete(Config.t(), atom) :: {:ok, Flag.t()} | {:error, term}
  def delete(%Config{store_legacy?: false, store: store} = conf, flag_name),
    do: store.delete(conf, flag_name)

  def delete(%Config{store: store}, flag_name), do: store.delete(flag_name)

  @doc false
  @spec all_flags(Config.t()) :: {:ok, [Flag.t()]} | {:error, term}
  def all_flags(%Config{store_legacy?: false, store: store} = conf), do: store.all_flags(conf)
  def all_flags(%Config{store: store}), do: store.all_flags()

  @doc false
  @spec all_flag_names(Config.t()) :: {:ok, [atom]} | {:error, term}
  def all_flag_names(%Config{store_legacy?: false, store: store} = conf),
    do: store.all_flag_names(conf)

  def all_flag_names(%Config{store: store}), do: store.all_flag_names()
end
