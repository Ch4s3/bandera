defmodule Bandera.Store.Persistent do
  @moduledoc """
  Behaviour for durable flag storage adapters (Memory, Ecto, Redis).

  Every callback receives the calling instance's `%Bandera.Config{}` first; an
  adapter reads its settings (`conf.persistence`) and resource names (e.g.
  `conf.memory_table`) from it, so one adapter module serves several instances
  without collisions.

  An adapter whose storage could be shared by two instances by mistake (e.g. two
  instances pointed at the same SQL table) may implement the optional
  `c:storage_id/1`; a second instance claiming the same id fails to start.

  Adapters written before instances existed implement the callbacks without the
  leading config argument (`get/1`, `put/2`, ...). They keep working (Bandera
  detects and calls the old arities) but cannot tell instances apart.
  """

  alias Bandera.Config
  alias Bandera.Flag
  alias Bandera.Gate

  @doc "Reads a flag straight from durable storage. Returns `{:ok, flag}` or `{:error, reason}`."
  @callback get(Config.t(), flag_name :: atom) :: {:ok, Flag.t()} | {:error, term}

  @doc "Persists `gate` onto the flag and returns the updated flag (or `{:error, reason}`)."
  @callback put(Config.t(), flag_name :: atom, gate :: Gate.t()) ::
              {:ok, Flag.t()} | {:error, term}

  @doc "Removes a single `gate` from durable storage and returns the updated flag."
  @callback delete(Config.t(), flag_name :: atom, gate :: Gate.t()) ::
              {:ok, Flag.t()} | {:error, term}

  @doc "Removes the entire flag from durable storage and returns the resulting empty flag."
  @callback delete(Config.t(), flag_name :: atom) :: {:ok, Flag.t()} | {:error, term}

  @doc "Returns `{:ok, flags}` with every stored flag, or `{:error, reason}`."
  @callback all_flags(Config.t()) :: {:ok, [Flag.t()]} | {:error, term}

  @doc "Returns `{:ok, names}` with every stored flag name, or `{:error, reason}`."
  @callback all_flag_names(Config.t()) :: {:ok, [atom]} | {:error, term}

  @doc """
  Identifies the external storage `conf` points at (any term), or `nil` when the
  storage is private to the instance. Two running instances may not share an id.
  """
  @callback storage_id(Config.t()) :: term | nil

  @optional_callbacks storage_id: 1

  # ---- dispatch (instance-aware or legacy) ----

  @doc false
  @spec get(Config.t(), atom) :: {:ok, Flag.t()} | {:error, term}
  def get(%Config{persistence_legacy?: false, persistence_adapter: a} = conf, flag_name),
    do: a.get(conf, flag_name)

  def get(%Config{persistence_adapter: a}, flag_name), do: a.get(flag_name)

  @doc false
  @spec put(Config.t(), atom, Gate.t()) :: {:ok, Flag.t()} | {:error, term}
  def put(%Config{persistence_legacy?: false, persistence_adapter: a} = conf, flag_name, gate),
    do: a.put(conf, flag_name, gate)

  def put(%Config{persistence_adapter: a}, flag_name, gate), do: a.put(flag_name, gate)

  @doc false
  @spec delete(Config.t(), atom, Gate.t()) :: {:ok, Flag.t()} | {:error, term}
  def delete(%Config{persistence_legacy?: false, persistence_adapter: a} = conf, flag_name, gate),
    do: a.delete(conf, flag_name, gate)

  def delete(%Config{persistence_adapter: a}, flag_name, gate), do: a.delete(flag_name, gate)

  @doc false
  @spec delete(Config.t(), atom) :: {:ok, Flag.t()} | {:error, term}
  def delete(%Config{persistence_legacy?: false, persistence_adapter: a} = conf, flag_name),
    do: a.delete(conf, flag_name)

  def delete(%Config{persistence_adapter: a}, flag_name), do: a.delete(flag_name)

  @doc false
  @spec all_flags(Config.t()) :: {:ok, [Flag.t()]} | {:error, term}
  def all_flags(%Config{persistence_legacy?: false, persistence_adapter: a} = conf),
    do: a.all_flags(conf)

  def all_flags(%Config{persistence_adapter: a}), do: a.all_flags()

  @doc false
  @spec all_flag_names(Config.t()) :: {:ok, [atom]} | {:error, term}
  def all_flag_names(%Config{persistence_legacy?: false, persistence_adapter: a} = conf),
    do: a.all_flag_names(conf)

  def all_flag_names(%Config{persistence_adapter: a}), do: a.all_flag_names()

  @doc false
  @spec storage_id(Config.t()) :: term | nil
  def storage_id(%Config{persistence_legacy?: false, persistence_adapter: a} = conf) do
    if Code.ensure_loaded?(a) and function_exported?(a, :storage_id, 1),
      do: a.storage_id(conf),
      else: nil
  end

  def storage_id(%Config{}), do: nil
end
