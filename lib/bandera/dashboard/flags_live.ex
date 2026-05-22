if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Bandera.Dashboard.FlagsLive do
    @moduledoc "The Bandera flag dashboard LiveView."
    use Phoenix.LiveView

    import Bandera.Dashboard.Components

    @impl true
    def mount(_params, _session, socket) do
      {:ok, socket}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.styles />
      <div class="bandera-wrap">
        <h1>Bandera</h1>
      </div>
      """
    end
  end
end
