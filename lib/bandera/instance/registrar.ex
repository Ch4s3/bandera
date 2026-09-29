defmodule Bandera.Instance.Registrar do
  @moduledoc false
  # First child of every instance supervisor. Publishes the instance's config to
  # `:persistent_term` and claims the instance's external storage, refusing to start
  # (and so failing the whole instance) if another running instance already uses
  # that storage. On shutdown it erases the config, so calls against a stopped named
  # instance fail loudly instead of silently reaching a half-torn-down instance.

  use GenServer

  alias Bandera.Config
  alias Bandera.Store.Persistent

  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(%Config{} = conf), do: GenServer.start_link(__MODULE__, conf)

  @impl GenServer
  def init(%Config{name: name, start_opts: start_opts}) do
    Process.flag(:trap_exit, true)

    # Rebuild from the start options (rather than reusing the config the instance
    # was started with) so that, if this process is ever restarted, it republishes
    # the current settings instead of undoing a `Bandera.reload_config/1`.
    conf = Config.new(start_opts)

    case claim(conf) do
      :ok ->
        Config.put(conf)
        {:ok, name}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def terminate(_reason, name), do: Config.erase(name)

  # Only the two-level store reads the persistence adapter.
  defp claim(%Config{store: Bandera.Store.TwoLevel, name: name} = conf) do
    case Persistent.storage_id(conf) do
      nil -> :ok
      id -> Bandera.Instance.claim_storage(id, name)
    end
  end

  defp claim(_conf), do: :ok
end
