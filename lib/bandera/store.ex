defmodule Bandera.Store do
  @moduledoc """
  Behaviour for the active store the public API talks to.

  The concrete store is selected at RUNTIME via `Bandera.Config` (default
  `Bandera.Store.TwoLevel`). `lookup/1` may add caching; writes go to the
  persistent layer.
  """

  alias Bandera.Flag
  alias Bandera.Gate

  @doc "Reads a flag by name (may serve from cache). Returns `{:ok, flag}` or `{:error, reason}`."
  @callback lookup(flag_name :: atom) :: {:ok, Flag.t()} | {:error, term}

  @doc "Writes `gate` onto the flag and returns the updated flag (or `{:error, reason}`)."
  @callback put(flag_name :: atom, gate :: Gate.t()) :: {:ok, Flag.t()} | {:error, term}

  @doc "Removes a single `gate` from the flag and returns the updated flag (or `{:error, reason}`)."
  @callback delete(flag_name :: atom, gate :: Gate.t()) :: {:ok, Flag.t()} | {:error, term}

  @doc "Removes the entire flag and returns the resulting (empty) flag (or `{:error, reason}`)."
  @callback delete(flag_name :: atom) :: {:ok, Flag.t()} | {:error, term}

  @doc "Returns `{:ok, flags}` with every stored flag, or `{:error, reason}`."
  @callback all_flags() :: {:ok, [Flag.t()]} | {:error, term}

  @doc "Returns `{:ok, names}` with every stored flag name, or `{:error, reason}`."
  @callback all_flag_names() :: {:ok, [atom]} | {:error, term}

  @doc "The runtime-selected active store module."
  @spec active() :: module
  def active, do: Bandera.Config.store()
end
