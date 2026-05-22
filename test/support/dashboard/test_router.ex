defmodule Bandera.Dashboard.TestRouter do
  use Phoenix.Router

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router
  import Bandera.Dashboard.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:put_root_layout, html: {Bandera.Dashboard.TestLayouts, :root})
  end

  scope "/" do
    pipe_through(:browser)
    bandera_dashboard("/flags")
  end
end
