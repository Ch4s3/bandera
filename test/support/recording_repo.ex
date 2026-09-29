defmodule Bandera.RecordingRepo do
  @moduledoc """
  A stub "repo" that records every call the Ecto persistence adapter makes,
  instead of touching a real database. Used to assert that a `prefix:` option
  configured on an instance reaches EVERY repo call the adapter issues (`all`,
  `insert_all`, `delete_all`, `transaction`) — a single missed call would
  silently write to the wrong Postgres schema in production.

  Sends `{:repo_call, fun, opts}` to the pid configured via
  `config :bandera, :recording_repo_pid` and returns plausible results so the
  adapter's own post-processing (e.g. `Serializer.deserialize_flag/2`) does not
  raise.
  """

  @spec all(Ecto.Query.t(), keyword) :: []
  def all(_query, opts) do
    record(:all, opts)
    []
  end

  @spec insert_all({String.t(), module}, [map], keyword) :: {non_neg_integer, nil}
  def insert_all(_source, rows, opts) do
    record(:insert_all, opts)
    {length(rows), nil}
  end

  @spec delete_all(Ecto.Query.t(), keyword) :: {non_neg_integer, nil}
  def delete_all(_query, opts) do
    record(:delete_all, opts)
    {0, nil}
  end

  @spec transaction((-> result), keyword) :: {:ok, result} when result: term
  def transaction(fun, opts) when is_function(fun, 0) do
    record(:transaction, opts)
    {:ok, fun.()}
  end

  defp record(fun, opts) do
    :bandera |> Application.fetch_env!(:recording_repo_pid) |> send({:repo_call, fun, opts})
  end
end
