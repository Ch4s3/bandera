# Bandera Flag Dashboard

Bandera ships an optional LiveView dashboard for browsing and managing flags. It
lives in the core library but is inert unless your app depends on
`phoenix_live_view`. It ships **no JavaScript** and needs **no asset-pipeline
changes**: it inherits your app's layout and runs on your existing LiveView
socket.

## Install in a Phoenix app

The dashboard is a LiveView that runs inside your app. It needs LiveView wired up
(a socket + `app.js`), Bandera configured with a storage backend, and a route
mounted behind your auth. Apps generated with `mix phx.new --live` already have
the LiveView pieces (step 2).

### 1. Add the dependencies

```elixir
# mix.exs
def deps do
  [
    {:bandera, "~> 0.1"},
    {:phoenix_live_view, "~> 1.0"}
  ]
end
```

Run `mix deps.get`. The dashboard only compiles when `phoenix_live_view` is
present — without it, Bandera still works as a plain flag library.

### 2. Make sure LiveView is wired up

The dashboard reuses your app's LiveView socket and JavaScript; it ships none of
its own. If you generated your app with `--live` this is already done. Otherwise
confirm both:

```elixir
# lib/my_app_web/endpoint.ex
socket "/live", Phoenix.LiveView.Socket
```

```javascript
// assets/js/app.js
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: csrfToken}})
liveSocket.connect()
```

Mount the dashboard under a pipeline whose layout loads that `app.js` (the default
`:browser` pipeline does). Without the socket the page still renders, but toggles,
search, and gate editing won't work.

### 3. Configure a storage backend

The dashboard reads and writes real flags through Bandera, so configure a
persistence backend (defaults to in-memory, which is per-node and resets on
restart — fine for trying it out, not for production). For example, Ecto:

```elixir
# config/runtime.exs
config :bandera,
  store: Bandera.Store.TwoLevel,
  persistence: [adapter: Bandera.Store.Persistent.Ecto, repo: MyApp.Repo]
```

See the [README](README.md) for all backends (Ecto, Redis, in-memory) and
cross-node cache-bust notifications.

### 4. Mount the route behind your auth

```elixir
# lib/my_app_web/router.ex
import Bandera.Dashboard.Router

scope "/admin" do
  pipe_through [:browser, :require_admin]   # YOUR authentication/authorization
  bandera_dashboard "/flags"
end
```

The dashboard can toggle production features, so **never** mount it on an
unauthenticated route. You can also hook authorization into the LiveView's own
mount lifecycle with `:on_mount`:

```elixir
bandera_dashboard "/flags", on_mount: {MyAppWeb.AdminAuth, :ensure_admin}
```

Mount it more than once (e.g. per environment) by passing a distinct
`:live_session_name`.

### 5. Visit it

Start your server and open `/admin/flags`. Flags are created in code/IEx (e.g.
`Bandera.enable(:my_flag)`); the dashboard manages their gates from there.

The dashboard sets no root layout — it inherits the one from your pipeline. By
default its CSS is self-contained and inlined, with `bandera-`-prefixed selectors,
so it needs **no asset-pipeline changes** and won't clash with your styles. See
[Theming](#theming) to retheme it or switch to daisyUI.

## Grouping

Flags are grouped by a name-prefix convention: the part of the flag's name before
the first separator is the group. The separator defaults to `"_"`:

```elixir
config :bandera, dashboard: [group_separator: "_"]
```

So `:billing_checkout_v2` and `:billing_invoices` appear under **billing**. Flags
with no separator (e.g. `:beta`) appear under **Ungrouped**. Set
`group_separator: nil` to disable grouping.

## Theming

The dashboard has two themes, chosen by config:

```elixir
config :bandera, dashboard: [theme: :standalone]   # default
```

### `:standalone` (default)

A self-contained, inlined stylesheet with `bandera-`-prefixed selectors. No asset
pipeline, no daisyUI, no clashes. Colors, radii, and fonts are read as CSS custom
properties with built-in fallbacks, so you can retheme with a single rule — no
specificity battles, no `!important`:

```css
:root {
  --bandera-primary: #0ea5e9;     /* buttons, group headers, focus rings */
  --bandera-radius: 6px;          /* cards and inputs */
  --bandera-surface: #ffffff;     /* card background */
  --bandera-border: #e2e8f0;
  /* also: --bandera-fg, --bandera-muted, --bandera-surface-2,
     --bandera-radius-sm, --bandera-shadow, --bandera-primary-fg,
     --bandera-success, --bandera-off, --bandera-danger,
     --bandera-danger-border, --bandera-danger-bg, --bandera-font */
}
```

The defaults are a fixed light palette. For dark mode, set the variables (e.g.
inside your own `@media (prefers-color-scheme: dark)`), or use the `:daisyui`
theme below.

### `:daisyui`

```elixir
config :bandera, dashboard: [theme: :daisyui]
```

In this mode the dashboard emits daisyUI component classes (`btn`, `input`,
`select`, `alert`, …) and **no** inlined `<style>`, so it inherits your app's daisyUI theme
(including dark mode and brand colors). This requires your app to build daisyUI
itself, and — because Bandera ships compiled templates that Tailwind doesn't scan
by default — you must add Bandera to your Tailwind sources so the classes are
generated:

```css
/* assets/css/app.css (Tailwind v4 / Phoenix 1.8) */
@source "../../deps/bandera/lib";
```

(Tailwind v3: add `"../deps/bandera/lib/**/*.ex"` to `content` in
`tailwind.config.js`.) Without this, the dashboard renders unstyled.

## Live updates across nodes

If you've configured Bandera's `PhoenixPubSub` cache-bust notifications, open
dashboards refresh automatically when another node or operator changes a flag.

## What you can manage

Per flag: the boolean on/off toggle, per-actor gates, per-group gates, and a
percentage rollout (of actors or of time), plus clearing the whole flag. Search
filters the list as you type. (Creating brand-new flags from the UI is not in this
version — flags are created in code/IEx via `Bandera.enable/2`.)
