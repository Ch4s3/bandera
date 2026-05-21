ExUnit.start()

Bandera.Test.start()

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

# --- Redis: start a named connection if a local Redis is reachable, else skip :redis tests ---
case Bandera.Store.Persistent.Redis.start_link(sync_connect: true) do
  {:ok, _conn} -> :ok
  {:error, _reason} -> ExUnit.configure(exclude: [:redis])
end
