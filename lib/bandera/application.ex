defmodule Bandera.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Bandera.Config.reload()

    children =
      if Application.get_env(:bandera, :start_on_boot, true) do
        [Bandera.Store.Persistent.Memory, Bandera.Store.Cache]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Bandera.Supervisor)
  end
end
