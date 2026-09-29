# Running Multiple Instances

Bandera normally runs as a single, global flag set — the **default instance**,
configured with `config :bandera, ...` and started automatically at boot. This
guide covers running *several* isolated flag sets in one VM: each with its own
storage, cache, notifications, dashboard, and telemetry.

- [When to use this](#when-to-use-this)
- [The default instance is unchanged](#the-default-instance-is-unchanged)
- [Defining an instance](#defining-an-instance)
- [Calling an instance](#calling-an-instance)
- [Per-backend isolation](#per-backend-isolation)
- [Usage (stale-flag tracking) per instance](#usage-stale-flag-tracking-per-instance)
- [Dashboard per instance](#dashboard-per-instance)
- [Testing a named instance](#testing-a-named-instance)
- [Telemetry and audit](#telemetry-and-audit)
- [The `mix bandera.flags` task](#the-mix-banderaflags-task)
- [Reloading a named instance's config](#reloading-a-named-instances-config)
- [Custom (legacy) extension modules](#custom-legacy-extension-modules)
- [Worked example: an umbrella app](#worked-example-an-umbrella-app)

## When to use this

Reach for multiple instances when you have **several applications sharing one
VM** (the classic case is an umbrella app) and each needs its own, separately
scoped flags, storage, caches, and dashboard — so that toggling a flag in one
app can never affect another, and each app's flags can live in its own table,
schema, or Redis namespace.

**Don't** reach for this if you have a single app that just wants to organize
its flag names — a name prefix (`:billing_checkout`, `:billing_invoices`) and
the dashboard's [grouping](dashboard_guide.md#grouping) already solve that with
one instance and no extra moving parts.

## The default instance is unchanged

Everything about the default instance — its config keys, its storage, its
dashboard, existing calls to `Bandera.enabled?/2` and friends — behaves exactly
as before. Adding named instances is purely additive: you only pay for it in
the apps that opt in.

## Defining an instance

Define a module per instance and `use Bandera`:

```elixir
defmodule MyApp.Flags do
  use Bandera, otp_app: :my_app
end
```

Configure it like the default instance, but under your own `otp_app` and the
module name:

```elixir
# config/config.exs
config :my_app, MyApp.Flags,
  persistence: [adapter: Bandera.Store.Persistent.Ecto, repo: MyApp.Repo,
                ecto_table_name: "my_app_flags"]
```

Add the module to your app's supervision tree:

```elixir
# lib/my_app/application.ex
children = [MyApp.Repo, MyApp.Flags]
```

`use Bandera` gives `MyApp.Flags` a `child_spec/1`/`start_link/1` and every
public function of `Bandera` (`enabled?/2`, `enable/2`, `disable/2`, `clear/2`,
`variant/2`, `put_variants/3`, `put_segment/3`, `all_flag_names/1`,
`all_flags/1`, `get_flag/2`, `stale_flags/1`, `reload_config/1`) bound to its
own instance — you never pass `instance:` when calling through the module.

`:otp_app` is optional: `use Bandera` alone works too, reading only whatever
options are passed to `child_spec/1`/`start_link/1` (handy for tests or
instances that don't need application env). You can also start an instance
with no module at all:

```elixir
children = [{Bandera, name: MyApp.Flags, persistence: [adapter: Bandera.Store.Persistent.Memory]}]
```

If an umbrella app doesn't use the default instance at all, stop it from
starting at boot:

```elixir
config :bandera, start_on_boot: false
```

(The `Bandera.Registry` that tracks storage claims across instances always
starts, regardless of this setting.)

### Libraries meant to be embedded

An application that is itself embedded in other applications (a dependency
whose LiveViews a host mounts, say) can ship its instance's settings with the
module instead of asking every host to copy them into its config — a host never
loads a dependency's `config/*.exs`:

```elixir
defmodule MyLib.Flags do
  use Bandera,
    otp_app: :my_lib,
    defaults: [
      persistence: [adapter: Bandera.Store.Persistent.Ecto, repo: MyLib.Repo,
                    prefix: "my_lib"],
      cache_bust_notifications: [enabled: true, adapter: Bandera.Notifications.PhoenixPubSub,
                                 client: MyLib.Flags.PubSub]
    ]
end
```

`defaults:` is the lowest-precedence layer: application env
(`config :my_lib, MyLib.Flags, ...` — in the library's own config or a host's)
refines it one level deep, and explicit `child_spec/1` options refine that. A
host therefore overrides only what it must, typically its test store:

```elixir
# the host's config/test.exs
config :my_lib, MyLib.Flags, store: Bandera.Store.ProcessScoped
```

`MyLib.Flags.__bandera_defaults__/0` returns the shipped defaults, e.g. for a
host test asserting that the library's storage differs from the host's own.

## Calling an instance

Through the facade module, no `instance:` needed:

```elixir
MyApp.Flags.enabled?(:checkout, for: current_user)
MyApp.Flags.enable(:checkout)
```

Or against `Bandera` directly, passing `instance:`:

```elixir
Bandera.enabled?(:checkout, instance: MyApp.Flags, for: current_user)
```

**There is no implicit per-app selection.** `Bandera.enabled?/2` (and every
other Bandera function) with no `instance:` *always* targets the default
instance — never "whichever instance this app happens to own." Code that is
shared across apps (a library function, a plug, a background job used by more
than one app) must explicitly call the right instance, either through its
facade module or by passing `instance: MyApp.Flags`.

## Per-backend isolation

Every instance's storage must be independent. Memory, Redis, and notifications
are isolated automatically; for Ecto, where two instances could point at the
same table by mistake, Bandera checks at start time (via the adapter's
`storage_id/1`) and refuses to start the second one.

### Memory

Automatic. Each instance gets its own ETS table; nothing to configure.

### Ecto

Give each instance its own table and/or its own Postgres schema:

```elixir
config :my_app, MyApp.Flags,
  persistence: [
    adapter: Bandera.Store.Persistent.Ecto,
    repo: MyApp.Repo,
    ecto_table_name: "my_app_flags",
    prefix: "my_app"   # optional Postgres schema; must already exist
  ]
```

Create the table (and its options) from a migration:

```elixir
defmodule MyApp.Repo.Migrations.CreateMyAppFlags do
  use Ecto.Migration

  def up,
    do: Bandera.Ecto.Migrations.up(table: "my_app_flags", prefix: "my_app")

  def down,
    do: Bandera.Ecto.Migrations.down(table: "my_app_flags", prefix: "my_app")
end
```

`up/1` also accepts `:usage_table` (see [Usage](#usage-stale-flag-tracking-per-instance)
below). At start time, an instance whose database, prefix, and table all match a
*running* instance refuses to start (the database is identified by the repo's
host, port, and database name, so this also catches two different repo modules
pointed at the same database): its supervisor fails to start its first
child with the reason

```elixir
{:storage_conflict, {Bandera.Store.Persistent.Ecto, repo, prefix, table}, other_instance}
```

where `other_instance` is the name of the instance already using that storage.
Give every instance sharing a repo either a distinct table or a distinct
`prefix`.

### Redis

Automatic. Each instance's keys are namespaced by its name — `bandera:flag:*`
for the default instance, `bandera:{MyApp.Flags}:flag:*` for a named one — so
several instances can share one Redis connection/database without colliding.

### Notifications

Automatic. Each instance publishes cache-bust notifications on its own
channel/topic — `"bandera:changes"` for the default instance,
`"bandera:{MyApp.Flags}:changes"` for a named one — so a change in one instance
never busts another instance's cache.

## Usage (stale-flag tracking) per instance

`Bandera.Usage` tracks one instance; start a tracker per instance you want
stale-flag detection for:

```elixir
children = [MyApp.Flags, {Bandera.Usage, instance: MyApp.Flags}]
```

Then `MyApp.Flags.stale_flags/1`, or `Bandera.Usage.last_evaluated/2`,
`Bandera.Usage.ready?/1`, and `Bandera.Usage.flush/1` (all taking the instance
name as their first argument).

With the Ecto adapter, give each instance's tracker its own usage table —
otherwise two trackers writing to the same table would mix their instances'
history:

```elixir
config :my_app, MyApp.Flags,
  persistence: [..., usage_table_name: "my_app_usage"]
```

```elixir
def up, do: Bandera.Ecto.Migrations.up_usage(usage_table: "my_app_usage", prefix: "my_app")
```

A tracker whose usage table is already claimed by another running tracker
refuses to start, the same way persistence storage does.

## Dashboard per instance

Pass `instance:` to `bandera_dashboard`, and mount as many dashboards as you
have instances, each at its own path:

```elixir
import Bandera.Dashboard.Router

scope "/admin" do
  pipe_through [:browser, :require_admin]

  bandera_dashboard "/flags"                       # default instance
  bandera_dashboard "/my-app-flags", instance: MyApp.Flags
end
```

Each dashboard gets its own `live_session` name automatically (derived from the
instance), so mounting several in one router needs no extra options. Pass
`:live_session_name` yourself only if you mount the *same* instance's dashboard
more than once.

## Testing a named instance

Configure the instance's store as `Bandera.Store.ProcessScoped` in the test
environment, the same way you would for the default instance:

```elixir
# config/test.exs
config :my_app, MyApp.Flags, store: Bandera.Store.ProcessScoped

# test/test_helper.exs
Bandera.Test.start()
```

The instance itself still starts from your application's supervision tree as
usual; only its store changes. `Bandera.Test.start/0` is instance-agnostic — call it once regardless of how
many instances you test. `use Bandera.Test, instance: MyApp.Flags` binds
`enable_flag/1,2`, `disable_flag/1,2`, and the `@tag feature_flags:` setup to
that instance:

```elixir
defmodule MyApp.CheckoutTest do
  use ExUnit.Case, async: true
  use Bandera.Test, instance: MyApp.Flags

  @tag feature_flags: [checkout: true]
  test "feature on via tag" do
    assert MyApp.Flags.enabled?(:checkout)
  end
end
```

Outside `use Bandera.Test`, the fully-qualified helpers take `instance:`
directly: `Bandera.Test.put_flag(:checkout, true, nil, instance: MyApp.Flags)`,
`Bandera.Test.clear(:checkout, instance: MyApp.Flags)`. `Bandera.Test.reset/0`
clears the current process's overrides for *every* instance at once.

## Telemetry and audit

Every `:telemetry` event Bandera emits carries `instance` in its metadata (see
`Bandera.Telemetry`), and every `%Bandera.Audit.Event{}` carries an `instance`
field — one audit handler sees the changes of every instance:

```elixir
Bandera.Audit.attach(:my_audit, fn event ->
  MyApp.AuditLog.insert!(%{instance: event.instance, action: event.action, flag: event.flag_name})
end)
```

## The `mix bandera.flags` task

Pass `--instance` to target a named instance instead of the default one:

```bash
mix bandera.flags --instance MyApp.Flags
mix bandera.flags --instance :my_flags --stale --older-than 30
```

## Reloading a named instance's config

`reload_config/1` (or the instance-bound `MyApp.Flags.reload_config/1`)
re-reads application env and start options into the running instance's
config — the same as `Bandera.reload_config/0` does for the default instance:

```elixir
Application.put_env(:my_app, MyApp.Flags, cache: [ttl: 60])
Bandera.reload_config(instance: MyApp.Flags)
# or, through the facade:
MyApp.Flags.reload_config()
```

Settings read on each call — the cache's `enabled`/`ttl`, `auto_create`, the
dashboard settings (including `stale_older_than`), and the Ecto adapter's
repo, table, and prefix — take effect as soon as you reload; changing them with
`Application.put_env/3` alone has no effect until then. Settings used to start
a process — the persistence adapter itself, Redis connection options, and the
notifications adapter and its connection — only apply when that instance is
restarted.

## Custom (legacy) extension modules

If you have a custom store, persistence adapter, or notifications adapter
written before instances existed (i.e. it implements the old, config-less
callbacks — `lookup/1` instead of `lookup/2`, and so on), it keeps working at
runtime unchanged, against whichever instance uses it (it can't tell instances
apart, so give each instance its own module or migrate it). If it declares
`@behaviour`, though, it now gets compile warnings — each new config-first
callback is reported as not implemented, and each `@impl` on an old callback as
unknown — which fail a `--warnings-as-errors` build. Migrate it to the
config-first callbacks (see the `Bandera.Store`, `Bandera.Store.Persistent`, and
`Bandera.Notifications` moduledocs), or drop its `@behaviour`/`@impl` lines.

## Worked example: an umbrella app

Two apps in one umbrella, each with its own flags:

```elixir
# apps/billing/lib/billing/flags.ex
defmodule Billing.Flags do
  use Bandera, otp_app: :billing
end

# apps/billing/config/config.exs
config :billing, Billing.Flags,
  persistence: [
    adapter: Bandera.Store.Persistent.Ecto,
    repo: Billing.Repo,
    ecto_table_name: "billing_flags",
    usage_table_name: "billing_flags_usage"
  ]

# apps/billing/lib/billing/application.ex
children = [Billing.Repo, Billing.Flags, {Bandera.Usage, instance: Billing.Flags}]
```

```elixir
# apps/reporting/lib/reporting/flags.ex
defmodule Reporting.Flags do
  use Bandera, otp_app: :reporting
end

# apps/reporting/config/config.exs
config :reporting, Reporting.Flags,
  persistence: [adapter: Bandera.Store.Persistent.Memory]

# apps/reporting/lib/reporting/application.ex
children = [Reporting.Flags]
```

```elixir
# in the umbrella's root config, if no app uses the default instance:
config :bandera, start_on_boot: false
```

```elixir
# a migration in the billing app
defmodule Billing.Repo.Migrations.CreateBillingFlags do
  use Ecto.Migration

  def up,
    do: Bandera.Ecto.Migrations.up(table: "billing_flags", usage_table: "billing_flags_usage")

  def down,
    do: Bandera.Ecto.Migrations.down(table: "billing_flags", usage_table: "billing_flags_usage")
end
```

Calling code stays app-scoped:

```elixir
Billing.Flags.enable(:new_invoicing)
Billing.Flags.enabled?(:new_invoicing, for: current_user)

Reporting.Flags.enabled?(:new_dashboard)
```

`Billing.Flags` and `Reporting.Flags` never see each other's flags, storage, or
cache-bust notifications, and each can mount its own dashboard route:

```elixir
scope "/admin" do
  pipe_through [:browser, :require_admin]
  bandera_dashboard "/billing-flags", instance: Billing.Flags
  bandera_dashboard "/reporting-flags", instance: Reporting.Flags
end
```
