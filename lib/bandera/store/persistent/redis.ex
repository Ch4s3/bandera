if Code.ensure_loaded?(Redix) do
  defmodule Bandera.Store.Persistent.Redis do
    @moduledoc """
    Redis persistence adapter (via Redix).

    Each flag is a Redis hash (`<namespace>:flag:<name>`) keyed by gate id; all
    flag names live in a set (`<namespace>:flag_names`). `<namespace>` is the
    instance's `conf.namespace` — `"bandera"` for the default instance (so its
    keys are exactly the historical `bandera:flag:<name>` / `bandera:flag_names`)
    and `"bandera:{MyApp.Flags}"` for a named instance, so several instances can
    share one Redis without colliding. The connection options are read at start
    time from the instance's `persistence: [redis: <keyword of Redix opts>]` —
    nothing is fixed at compile time.

    The connection is started by the instance's supervision tree when the Redis
    adapter is configured:

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

    @doc "Child spec so the connection can be added to a supervision tree."
    @spec child_spec(Config.t() | keyword) :: Supervisor.child_spec()
    def child_spec(opts) when is_list(opts) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
    end

    def child_spec(%Config{} = conf) do
      %{id: {__MODULE__, conf.name}, start: {__MODULE__, :start_link, [conf]}}
    end

    @doc """
    Starts the named Redix connection.

    Given a `%Bandera.Config{}`, the connection is named `conf.redis_conn` and its
    options come from `conf.persistence[:redis]`; given a keyword list (e.g.
    `start_supervised!(Bandera.Store.Persistent.Redis)`), the default instance's
    connection is started, with `opts` merged over `config :bandera, persistence:
    [redis: ...]`.
    """
    @spec start_link(Config.t() | keyword) :: GenServer.on_start()
    def start_link(conf_or_opts \\ [])

    def start_link(%Config{} = conf) do
      redix_opts =
        conf.persistence
        |> Keyword.get(:redis, [])
        |> Keyword.put(:name, conf.redis_conn)

      Redix.start_link(redix_opts)
    end

    def start_link(opts) when is_list(opts) do
      conf = Config.new()

      redix_opts =
        conf.persistence
        |> Keyword.get(:redis, [])
        |> Keyword.merge(opts)
        |> Keyword.put(:name, conf.redis_conn)

      Redix.start_link(redix_opts)
    end

    @impl Bandera.Store.Persistent
    def get(%Config{} = conf, flag_name) do
      case Redix.command(conf.redis_conn, ["HGETALL", key(conf, flag_name)]) do
        {:ok, flat} -> {:ok, Serializer.deserialize_flag(flag_name, flat)}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl Bandera.Store.Persistent
    def put(%Config{} = conf, flag_name, %Gate{} = gate) do
      {field, value} = Serializer.serialize(gate)
      name = to_string(flag_name)

      pipeline =
        Redix.transaction_pipeline(conf.redis_conn, [
          ["SADD", flags_set(conf), name],
          ["HSET", key(conf, flag_name), field, value]
        ])

      case check_pipeline(pipeline) do
        :ok -> get(conf, flag_name)
        {:error, reason} -> {:error, reason}
      end
    end

    @impl Bandera.Store.Persistent
    def delete(%Config{} = conf, flag_name, %Gate{} = gate) do
      case Redix.command(conf.redis_conn, ["HDEL", key(conf, flag_name), Serializer.field(gate)]) do
        {:ok, _count} -> get(conf, flag_name)
        {:error, reason} -> {:error, reason}
      end
    end

    @impl Bandera.Store.Persistent
    def delete(%Config{} = conf, flag_name) do
      name = to_string(flag_name)

      pipeline =
        Redix.transaction_pipeline(conf.redis_conn, [
          ["SREM", flags_set(conf), name],
          ["DEL", key(conf, flag_name)]
        ])

      case check_pipeline(pipeline) do
        :ok -> {:ok, Flag.new(flag_name, [])}
        {:error, reason} -> {:error, reason}
      end
    end

    def delete(flag_name, %Gate{} = gate) when is_atom(flag_name),
      do: delete(Config.get(), flag_name, gate)

    @impl Bandera.Store.Persistent
    def all_flag_names(%Config{} = conf) do
      case Redix.command(conf.redis_conn, ["SMEMBERS", flags_set(conf)]) do
        {:ok, names} -> {:ok, Enum.map(names, &String.to_atom/1)}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl Bandera.Store.Persistent
    def all_flags(%Config{} = conf) do
      with {:ok, names} <- all_flag_names(conf) do
        names
        |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
          case get(conf, name) do
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

    defp key(conf, flag_name), do: "#{conf.namespace}:flag:#{flag_name}"
    defp flags_set(conf), do: "#{conf.namespace}:flag_names"

    # transaction_pipeline returns {:ok, results} even if a command inside the
    # transaction errored — each element can be a %Redix.Error{}. Surface those.
    defp check_pipeline({:ok, results}) do
      case Enum.find(results, &match?(%Redix.Error{}, &1)) do
        nil -> :ok
        %Redix.Error{} = error -> {:error, error}
      end
    end

    defp check_pipeline({:error, reason}), do: {:error, reason}
    # ---- default-instance forms (backward compatibility) ----
    # The pre-instance arities, acting on the default instance (the
    # `delete(flag_name, gate)` form sits with the `delete/2` callback above).

    @doc false

    @spec get(atom) :: {:ok, Bandera.Flag.t()} | {:error, term}
    def get(flag_name) when is_atom(flag_name), do: get(Config.get(), flag_name)

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
