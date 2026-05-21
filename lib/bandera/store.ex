defmodule Bandera.Store do
  @moduledoc """
  Behaviour for the active store the public API talks to.

  The concrete store is selected at RUNTIME via `Bandera.Config` (default
  `Bandera.Store.TwoLevel`). `lookup/1` may add caching; writes go to the
  persistent layer.
  """

  alias Bandera.Flag
  alias Bandera.Gate

  @callback lookup(flag_name :: atom) :: {:ok, Flag.t()} | {:error, term}
  @callback put(flag_name :: atom, gate :: Gate.t()) :: {:ok, Flag.t()} | {:error, term}
  @callback delete(flag_name :: atom, gate :: Gate.t()) :: {:ok, Flag.t()} | {:error, term}
  @callback delete(flag_name :: atom) :: {:ok, Flag.t()} | {:error, term}
  @callback all_flags() :: {:ok, [Flag.t()]} | {:error, term}
  @callback all_flag_names() :: {:ok, [atom]} | {:error, term}

  @doc "The runtime-selected active store module."
  @spec active() :: module
  def active, do: Bandera.Config.store()
end
