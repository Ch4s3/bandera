defmodule Bandera.Store.Persistent do
  @moduledoc "Behaviour for durable flag storage adapters (Memory, Ecto, Redis)."

  alias Bandera.Flag
  alias Bandera.Gate

  @callback get(flag_name :: atom) :: {:ok, Flag.t()} | {:error, term}
  @callback put(flag_name :: atom, gate :: Gate.t()) :: {:ok, Flag.t()} | {:error, term}
  @callback delete(flag_name :: atom, gate :: Gate.t()) :: {:ok, Flag.t()} | {:error, term}
  @callback delete(flag_name :: atom) :: {:ok, Flag.t()} | {:error, term}
  @callback all_flags() :: {:ok, [Flag.t()]} | {:error, term}
  @callback all_flag_names() :: {:ok, [atom]} | {:error, term}
end
