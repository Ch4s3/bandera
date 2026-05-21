defmodule Bandera.Store.Persistent do
  @moduledoc "Behaviour for durable flag storage adapters (Memory, Ecto, Redis)."

  alias Bandera.Flag
  alias Bandera.Gate

  @doc "Reads a flag straight from durable storage. Returns `{:ok, flag}` or `{:error, reason}`."
  @callback get(flag_name :: atom) :: {:ok, Flag.t()} | {:error, term}

  @doc "Persists `gate` onto the flag and returns the updated flag (or `{:error, reason}`)."
  @callback put(flag_name :: atom, gate :: Gate.t()) :: {:ok, Flag.t()} | {:error, term}

  @doc "Removes a single `gate` from durable storage and returns the updated flag."
  @callback delete(flag_name :: atom, gate :: Gate.t()) :: {:ok, Flag.t()} | {:error, term}

  @doc "Removes the entire flag from durable storage and returns the resulting empty flag."
  @callback delete(flag_name :: atom) :: {:ok, Flag.t()} | {:error, term}

  @doc "Returns `{:ok, flags}` with every stored flag, or `{:error, reason}`."
  @callback all_flags() :: {:ok, [Flag.t()]} | {:error, term}

  @doc "Returns `{:ok, names}` with every stored flag name, or `{:error, reason}`."
  @callback all_flag_names() :: {:ok, [atom]} | {:error, term}
end
