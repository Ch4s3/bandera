if Code.ensure_loaded?(Redix) do
  defmodule Bandera.Store.Persistent.Redis do
    @moduledoc """
    Redis persistence adapter (via Redix).

    Each flag is a Redis hash (`bandera:flag:<name>`) keyed by gate id; all flag
    names live in a set (`bandera:flag_names`). The connection options are read at
    start time from `config :bandera, persistence: [redis: <keyword of Redix opts>]`
    — nothing is fixed at compile time.

    Add the connection to your supervision tree (or let `Bandera.Application` start
    it when the Redis adapter is configured):

        config :bandera,
          persistence: [adapter: Bandera.Store.Persistent.Redis, redis: [host: "localhost", port: 6379]]

    ## Errors

    Connection/command failures return `{:error, reason}` (a `Redix.Error` or
    `Redix.ConnectionError`).
    """

    @behaviour Bandera.Store.Persistent

    alias Bandera.Config
    alias Bandera.Flag
    alias Bandera.Gate
    alias Bandera.Store.Persistent.Redis.Serializer

    @conn __MODULE__
    @prefix "bandera:flag:"
    @flags_set "bandera:flag_names"

    @doc "Child spec so the connection can be added to a supervision tree."
    @spec child_spec(keyword) :: Supervisor.child_spec()
    def child_spec(opts) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
    end

    @doc "Start the named Redix connection. Options merge over `config :bandera, persistence: [redis: ...]`."
    @spec start_link(keyword) :: GenServer.on_start()
    def start_link(opts \\ []) do
      redix_opts =
        Config.persistence()
        |> Keyword.get(:redis, [])
        |> Keyword.merge(opts)
        |> Keyword.put(:name, @conn)

      Redix.start_link(redix_opts)
    end

    @impl Bandera.Store.Persistent
    def get(flag_name) do
      case Redix.command(@conn, ["HGETALL", key(flag_name)]) do
        {:ok, flat} -> {:ok, Serializer.deserialize_flag(flag_name, flat)}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl Bandera.Store.Persistent
    def put(flag_name, %Gate{} = gate) do
      {field, value} = Serializer.serialize(gate)
      name = to_string(flag_name)

      pipeline =
        Redix.transaction_pipeline(@conn, [
          ["SADD", @flags_set, name],
          ["HSET", key(flag_name), field, value]
        ])

      case check_pipeline(pipeline) do
        :ok -> get(flag_name)
        {:error, reason} -> {:error, reason}
      end
    end

    @impl Bandera.Store.Persistent
    def delete(flag_name, %Gate{} = gate) do
      case Redix.command(@conn, ["HDEL", key(flag_name), Serializer.field(gate)]) do
        {:ok, _count} -> get(flag_name)
        {:error, reason} -> {:error, reason}
      end
    end

    @impl Bandera.Store.Persistent
    def delete(flag_name) do
      name = to_string(flag_name)

      pipeline =
        Redix.transaction_pipeline(@conn, [
          ["SREM", @flags_set, name],
          ["DEL", key(flag_name)]
        ])

      case check_pipeline(pipeline) do
        :ok -> {:ok, Flag.new(flag_name, [])}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl Bandera.Store.Persistent
    def all_flag_names do
      case Redix.command(@conn, ["SMEMBERS", @flags_set]) do
        {:ok, names} -> {:ok, Enum.map(names, &String.to_atom/1)}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl Bandera.Store.Persistent
    def all_flags do
      with {:ok, names} <- all_flag_names() do
        names
        |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
          case get(name) do
            {:ok, flag} -> {:cont, {:ok, [flag | acc]}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, flags} -> {:ok, Enum.reverse(flags)}
          error -> error
        end
      end
    end

    defp key(flag_name), do: @prefix <> to_string(flag_name)

    # transaction_pipeline returns {:ok, results} even if a command inside the
    # transaction errored — each element can be a %Redix.Error{}. Surface those.
    defp check_pipeline({:ok, results}) do
      case Enum.find(results, &match?(%Redix.Error{}, &1)) do
        nil -> :ok
        %Redix.Error{} = error -> {:error, error}
      end
    end

    defp check_pipeline({:error, reason}), do: {:error, reason}
  end
end
