defmodule Bandera.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Bandera.Config.reload()

    # The registry tracks which instance owns which external storage; it runs even
    # when the default instance doesn't, so host-started instances can use it.
    children =
      [{Registry, keys: :unique, name: Bandera.Registry}] ++
        if Application.get_env(:bandera, :start_on_boot, true),
          do: [Bandera.Instance],
          else: []

    Supervisor.start_link(children, strategy: :one_for_one, name: Bandera.Supervisor)
  end
end
