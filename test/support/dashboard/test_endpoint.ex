defmodule Bandera.Dashboard.TestEndpoint do
  use Phoenix.Endpoint, otp_app: :bandera

  @session_options [
    store: :cookie,
    key: "_bandera_dashboard_test",
    signing_salt: "banderatest",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket)

  plug(Plug.Session, @session_options)
  plug(Bandera.Dashboard.TestRouter)
end
