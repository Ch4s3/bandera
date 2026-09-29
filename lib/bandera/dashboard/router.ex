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
      * `:instance` — the Bandera instance to bind the dashboard to (default the
        default instance). Mount more than one dashboard, each bound to its own
        instance, by giving each a distinct `:instance`.
      * `:live_session_name` — name for the generated `live_session` (default
        `:bandera_dashboard`, or derived from `:instance` when one is given, so
        two dashboards can be mounted in one router without clashing). Override
        when mounting more than once for the same instance.
      * `:on_mount` — an `on_mount` hook (or list) passed to the `live_session`,
        for plugging authz into the dashboard's own mount lifecycle.
    """

    @doc "Mounts the Bandera dashboard LiveView at `path`."
    defmacro bandera_dashboard(path, opts \\ []) do
      # `:instance` is given as a literal (an atom or a module alias); a module
      # alias arrives as `{:__aliases__, ...}` AST, so expand it to the atom it
      # names before using it as an ordinary value below.
      instance =
        opts
        |> Keyword.get(:instance, Bandera.Config.default_instance())
        |> Macro.expand(__CALLER__)

      session_name = Keyword.get(opts, :live_session_name, default_session_name(instance))
      on_mount = Keyword.get(opts, :on_mount)

      live_session_opts =
        Keyword.merge(
          if(on_mount, do: [on_mount: on_mount], else: []),
          session: Macro.escape(%{"bandera_instance" => instance})
        )

      quote do
        scope unquote(path), alias: false, as: false do
          import Phoenix.LiveView.Router

          live_session unquote(session_name), unquote(live_session_opts) do
            live("/", Bandera.Dashboard.FlagsLive, :index)
          end
        end
      end
    end

    # `Bandera` -> `:bandera_dashboard` (today's default, unchanged); a named
    # instance gets its own name so two dashboards can coexist in one router
    # without an explicit `:live_session_name`.
    defp default_session_name(instance) do
      if instance == Bandera.Config.default_instance() do
        :bandera_dashboard
      else
        instance
        |> Atom.to_string()
        |> String.replace_prefix("Elixir.", "")
        |> Macro.underscore()
        |> then(&:"bandera_dashboard_#{&1}")
      end
    end
  end
end
