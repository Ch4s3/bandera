# Local, interactive preview of the Bandera flag dashboard.
#
#     mix run --no-halt dev/preview.exs
#
# then open http://localhost:4001/flags
#
# Storage is in-memory and seeded with a handful of flags, so the preview is
# self-contained and resets on every run. Set BANDERA_THEME=daisyui to preview
# the daisyUI theme (note: it ships no CSS, so it only looks styled inside an app
# that builds daisyUI — in this bare preview it renders unstyled on purpose).

theme = if System.get_env("BANDERA_THEME") == "daisyui", do: :daisyui, else: :standalone

Application.put_env(:bandera, Bandera.DevPreview.Endpoint,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: 4001],
  server: true,
  adapter: Bandit.PhoenixAdapter,
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "bandera-preview-salt"],
  pubsub_server: Bandera.DevPreview.PubSub,
  check_origin: false
)

Application.put_env(:bandera, :dashboard, group_separator: "_", theme: theme)

defmodule Bandera.DevPreview.Layout do
  @moduledoc false
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Bandera dashboard preview</title>
        <style>
          body { margin: 0; background: #eef2f7; }
        </style>
        <script src="/assets/phoenix/phoenix.min.js"></script>
        <script src="/assets/phoenix_live_view/phoenix_live_view.min.js"></script>
      </head>
      <body>
        {@inner_content}
        <script>
          const csrf = document.querySelector("meta[name='csrf-token']").getAttribute("content");
          const liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
            params: { _csrf_token: csrf }
          });
          liveSocket.connect();
        </script>
      </body>
    </html>
    """
  end
end

defmodule Bandera.DevPreview.Router do
  @moduledoc false
  use Phoenix.Router

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router
  import Bandera.Dashboard.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_root_layout, html: {Bandera.DevPreview.Layout, :root})
  end

  scope "/" do
    pipe_through(:browser)
    bandera_dashboard("/flags")
  end
end

defmodule Bandera.DevPreview.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :bandera

  @session_options [
    store: :cookie,
    key: "_bandera_preview",
    signing_salt: "banderaprev",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket)

  plug(Plug.Static, at: "/assets/phoenix", from: :phoenix, gzip: false)
  plug(Plug.Static, at: "/assets/phoenix_live_view", from: :phoenix_live_view, gzip: false)

  plug(Plug.Session, @session_options)
  plug(Bandera.DevPreview.Router)
end

# `mix run` already started the :bandera app (in-memory store + cache). Just add
# a PubSub for the endpoint and the endpoint itself.
{:ok, _} =
  Supervisor.start_link(
    [
      {Phoenix.PubSub, name: Bandera.DevPreview.PubSub},
      Bandera.DevPreview.Endpoint
    ],
    strategy: :one_for_one
  )

Bandera.reload_config()

for {name, opts} <- [
      {:billing_invoices, []},
      {:billing_checkout, [for_percentage_of: {:actors, 0.25}]},
      {:billing_refunds, [for_actor: "user-42"]},
      {:billing_refunds, [for_actor: "user-77"]},
      {:billing_refunds, [for_group: "internal"]},
      {:search_reindex, [for_percentage_of: {:time, 0.10}]},
      {:beta_new_nav, []}
    ] do
  Bandera.enable(name, opts)
end

Bandera.disable(:billing_exports)

IO.puts("""

  Bandera dashboard preview running (theme: #{theme}).
  Open  →  http://localhost:4001/flags
  Stop  →  Ctrl-C twice
""")

Process.sleep(:infinity)
