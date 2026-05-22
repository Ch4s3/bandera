if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Bandera.Dashboard.Router do
    @moduledoc """
    Router macro for mounting the Bandera dashboard.

        import Bandera.Dashboard.Router

        scope "/admin" do
          pipe_through [:browser, :require_admin]   # YOUR auth pipeline
          bandera_dashboard "/flags"
        end

    Auth is the host's responsibility: always mount behind an authenticated,
    admin-only pipeline. The dashboard can toggle production features.

    The dashboard ships no JavaScript and sets no root layout: it inherits the
    layout from the pipeline/endpoint and runs on the host's existing LiveView
    socket. Mount it under a pipeline whose layout loads your `app.js`
    (the default `:browser` pipeline does).

    Options:
      * `:live_session_name` — name for the generated `live_session` (default
        `:bandera_dashboard`). Override when mounting more than once.
      * `:on_mount` — an `on_mount` hook (or list) passed to the `live_session`,
        for plugging authz into the dashboard's own mount lifecycle.
    """

    @doc "Mounts the Bandera dashboard LiveView at `path`."
    defmacro bandera_dashboard(path, opts \\ []) do
      session_name = Keyword.get(opts, :live_session_name, :bandera_dashboard)
      on_mount = Keyword.get(opts, :on_mount)
      live_session_opts = if on_mount, do: [on_mount: on_mount], else: []

      quote do
        scope unquote(path), alias: false, as: false do
          import Phoenix.LiveView.Router

          live_session unquote(session_name), unquote(live_session_opts) do
            live("/", Bandera.Dashboard.FlagsLive, :index)
          end
        end
      end
    end
  end
end
