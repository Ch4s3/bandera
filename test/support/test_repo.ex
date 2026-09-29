defmodule Bandera.TestRepo do
  use Ecto.Repo, otp_app: :bandera, adapter: Ecto.Adapters.SQLite3
end

defmodule Bandera.TestRepoAlias do
  @moduledoc false
  # A second repo module configured against the same database file as
  # Bandera.TestRepo (never started): storage claims must treat them as one
  # physical database.
  use Ecto.Repo, otp_app: :bandera, adapter: Ecto.Adapters.SQLite3
end
