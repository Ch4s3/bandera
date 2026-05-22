ExUnit.start()

Bandera.Test.start()

case Phoenix.PubSub.Supervisor.start_link(name: Bandera.Dashboard.TestPubSub) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

case Bandera.Dashboard.TestEndpoint.start_link() do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

# --- Ecto (SQLite) test repo: fresh DB + schema for the Ecto adapter tests ---
repo_config = Bandera.TestRepo.config()
adapter = Ecto.Adapters.SQLite3

_ = adapter.storage_down(repo_config)
:ok = adapter.storage_up(repo_config)

{:ok, _pid} = Bandera.TestRepo.start_link()

Ecto.Migrator.run(Bandera.TestRepo, [{20_260_101_000_000, Bandera.TestRepo.Migration}], :up,
  all: true,
  log: false
)

# --- Redis: run the :redis tests only if a local Redis is reachable. ---
# Redix links its connection to this process and, with sync_connect, a refused
# connection crashes that linked process; trap exits so an unreachable Redis
# excludes the :redis tests instead of taking down the test boot. Scope the flag
# to just the probe and restore it afterwards so the rest of the boot is unaffected.
previous_trap_exit = Process.flag(:trap_exit, true)

reachable? = fn conn ->
  try do
    match?({:ok, "PONG"}, Redix.command(conn, ["PING"]))
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end
end

redis_available? =
  case Bandera.Store.Persistent.Redis.start_link(sync_connect: true) do
    {:ok, conn} -> reachable?.(conn)
    {:error, {:already_started, conn}} -> reachable?.(conn)
    {:error, _reason} -> false
  end

# Drop any EXIT message from a crashed (unreachable) connection so it doesn't leak.
receive do
  {:EXIT, _pid, _reason} -> :ok
after
  0 -> :ok
end

Process.flag(:trap_exit, previous_trap_exit)

unless redis_available? do
  ExUnit.configure(exclude: [:redis])
end
