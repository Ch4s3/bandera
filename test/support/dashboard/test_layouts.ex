defmodule Bandera.Dashboard.TestLayouts do
  @moduledoc false
  use Phoenix.Component

  # Stands in for a host app's root layout. A real host's layout would also load
  # app.js + connect a LiveSocket; LiveViewTest doesn't execute JS, so it's omitted.
  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head><meta charset="utf-8" /><title>Host</title></head>
      <body>{@inner_content}</body>
    </html>
    """
  end
end
