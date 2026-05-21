defmodule Bandera.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Bandera.Config.reload()

    children =
      if Application.get_env(:bandera, :start_on_boot, true) do
        [Bandera.Store.Cache | persistence_children()]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Bandera.Supervisor)
  end

  # Start the process the configured persistence adapter needs (if any):
  # Memory owns an ETS table; Redis owns a Redix connection; Ecto uses the host
  # app's own Repo, so Bandera starts nothing for it.
  defp persistence_children do
    case Bandera.Config.persistence_adapter() do
      Bandera.Store.Persistent.Memory -> [Bandera.Store.Persistent.Memory]
      Bandera.Store.Persistent.Redis -> [Bandera.Store.Persistent.Redis]
      _other -> []
    end
  end
end
