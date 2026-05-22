# Migrating from fun_with_flags to Bandera

Bandera keeps the same public API and gate model you already use, so migration
is mostly a find-replace plus a config move. The one structural difference is
that **all configuration is read at runtime** — there is no `compile_env`, so
config can live in `config/runtime.exs` and change without a recompile.

This guide walks through the change end to end. Most apps only need steps 1–3.

## At a glance

| fun_with_flags | Bandera |
| --- | --- |
| `{:fun_with_flags, "~> x.y"}` | `{:bandera, "~> 0.1.0"}` |
| `FunWithFlags.enabled?/2`, `enable/2`, `disable/2`, `clear/2` | identical on `Bandera` |
| `FunWithFlags.Actor` / `FunWithFlags.Group` | `Bandera.Actor` / `Bandera.Group` |
| `config :fun_with_flags, :cache, ...` | `config :bandera, cache: [...]` |
| `FunWithFlags.Store.Persistent.Ecto` | `Bandera.Store.Persistent.Ecto` |
| `FunWithFlags.Store.Persistent.Redis` | `Bandera.Store.Persistent.Redis` |
| `FunWithFlags.Notifications.Redis` | `Bandera.Notifications.Redis` |
| `FunWithFlags.Notifications.PhoenixPubSub` | `Bandera.Notifications.PhoenixPubSub` |

## Step 1 — Swap the dependency

In `mix.exs`, replace the dependency:

```elixir
# before
{:fun_with_flags, "~> 1.0"},

# after
{:bandera, "~> 0.1.0"},
```

Keep whichever backend deps you already had (`ecto_sql`, `redix`,
`phoenix_pubsub`). They are optional in Bandera too — add only what you use.
If you adopt the test layer (step 7), also add:

```elixir
{:nimble_ownership, "~> 1.0", only: :test}
```

Then run `mix deps.get`.

## Step 2 — Rename the API calls

The function names and signatures are unchanged — only the module changes.
Find-replace `FunWithFlags` → `Bandera` across your code:

```elixir
# before
FunWithFlags.enable(:checkout)
FunWithFlags.enabled?(:beta, for: current_user)

# after
Bandera.enable(:checkout)
Bandera.enabled?(:beta, for: current_user)
```

All of these carry over with identical behavior:
`enabled?/2`, `enable/2`, `disable/2`, `clear/2`, `get_flag/1`, `all_flags/0`,
`all_flag_names/0`. The gate options (`for_actor:`, `for_group:`,
`for_percentage_of: {:time | :actors, ratio}`) are the same.

## Step 3 — Move the configuration

Change the config key from `:fun_with_flags` to `:bandera`. Bandera reads each
setting as a keyword under the app, and reads it at runtime — so you can keep it
in `config/config.exs` or move it to `config/runtime.exs`.

```elixir
# before — fun_with_flags
config :fun_with_flags, :cache,
  enabled: true,
  ttl: 900

config :fun_with_flags, :persistence,
  adapter: FunWithFlags.Store.Persistent.Ecto,
  repo: MyApp.Repo

config :fun_with_flags, :cache_bust_notifications,
  enabled: true,
  adapter: FunWithFlags.Notifications.PhoenixPubSub,
  client: MyApp.PubSub
```

```elixir
# after — Bandera
config :bandera,
  cache: [enabled: true, ttl: 900],
  persistence: [
    adapter: Bandera.Store.Persistent.Ecto,
    repo: MyApp.Repo
  ],
  cache_bust_notifications: [
    enabled: true,
    adapter: Bandera.Notifications.PhoenixPubSub,
    client: MyApp.PubSub
  ]
```

Defaults if you omit a section: in-memory store, cache on (900s TTL),
notifications off. Call `Bandera.reload_config/0` to re-read config at runtime.

> **Note on Redis connection options.** fun_with_flags uses one shared
> `config :fun_with_flags, :redis, [...]`. Bandera nests the Redix options under
> whichever component uses them:
>
> ```elixir
> config :bandera,
>   persistence: [adapter: Bandera.Store.Persistent.Redis, redis: [host: "localhost", port: 6379]],
>   cache_bust_notifications: [enabled: true, adapter: Bandera.Notifications.Redis, redis: [host: "localhost", port: 6379]]
> ```

## Step 4 — Re-implement the protocols

If you defined `FunWithFlags.Actor` / `FunWithFlags.Group` for your structs,
re-implement them under the `Bandera` namespace. The callbacks are the same —
`id/1` for actors, `in?/2` for groups:

```elixir
# before
defimpl FunWithFlags.Actor, for: MyApp.User do
  def id(user), do: "user:#{user.id}"
end

defimpl FunWithFlags.Group, for: MyApp.User do
  def in?(user, group_name), do: group_name in user.roles
end

# after
defimpl Bandera.Actor, for: MyApp.User do
  def id(user), do: "user:#{user.id}"
end

defimpl Bandera.Group, for: MyApp.User do
  def in?(user, group_name), do: group_name in user.roles
end
```

Bandera ships built-in implementations for binaries, integers, and maps with an
`:id` / `:groups` key, just like fun_with_flags.

## Step 5 — Persistence data

The Ecto table schema is the same shape as fun_with_flags (`flag_name`,
`gate_type`, `target`, `enabled`), so you have two options:

**Option A — keep your existing table.** Point Bandera at it by name and skip
any data migration:

```elixir
config :bandera,
  persistence: [
    adapter: Bandera.Store.Persistent.Ecto,
    repo: MyApp.Repo,
    ecto_table_name: "fun_with_flags_toggles"
  ]
```

**Option B — create a fresh Bandera table** and copy your rows over. Generate
the table from a migration:

```elixir
defmodule MyApp.Repo.Migrations.CreateBanderaFlags do
  use Ecto.Migration

  def up, do: Bandera.Ecto.Migrations.up()
  def down, do: Bandera.Ecto.Migrations.down()
end
```

The table name defaults to `"bandera_flags"` and is read from runtime config.

For **Redis** persistence, Bandera uses its own key prefix
(`bandera:flag:<name>` hashes plus a `bandera:flag_names` set). Either re-create
flags via the API after cutover, or migrate keys to the new prefix.

## Step 6 — Notifications

Swap the notification adapter module names; the behavior (cross-node
cache-busting) is unchanged:

- `FunWithFlags.Notifications.Redis` → `Bandera.Notifications.Redis`
- `FunWithFlags.Notifications.PhoenixPubSub` → `Bandera.Notifications.PhoenixPubSub`

The Phoenix.PubSub adapter still takes your PubSub server via `client:`.

## Step 7 — Tests (the setup is different)

**This is the one area where the migration is more than a rename.** With
fun_with_flags, flag state is global (shared ETS/DB), so toggling a flag in one
test is visible to every other test. The usual workarounds are running flag
tests with `async: false` and clearing flags manually (e.g. `FunWithFlags.clear/1`
in `setup`/`on_exit`) — and tests that write flags can deadlock under the Ecto
SQL sandbox.

Bandera replaces that model entirely with an **async-safe, process-scoped test
layer**. Overrides are scoped to the test process (and its spawned tasks), so
`async: true` tests don't bleed into each other, toggling a flag never touches
the database, and cleanup is automatic when the test process exits — no `setup`
or `on_exit` plumbing.

Because the model is different, you need to opt into it explicitly (this has no
fun_with_flags equivalent):

```elixir
# config/test.exs — select the process-scoped store
config :bandera, store: Bandera.Store.ProcessScoped

# test/test_helper.exs — start the override server once
Bandera.Test.start()
```

Add the test-layer dependency to `mix.exs` (see step 1):

```elixir
{:nimble_ownership, "~> 1.0", only: :test}
```

Then drop the `async: false` you needed for flag tests and `use Bandera.Test`:

```elixir
defmodule MyApp.CheckoutTest do
  use ExUnit.Case, async: true
  use Bandera.Test

  @tag feature_flags: [checkout: true]
  test "feature on via tag" do
    assert Bandera.enabled?(:checkout)
  end

  test "toggle in the body" do
    enable_flag(:beta)
    assert Bandera.enabled?(:beta)
  end
end
```

Existing tests that call `Bandera.enable/2`, `Bandera.disable/2`, etc. keep
working unchanged — when `Bandera.Store.ProcessScoped` is configured, those calls
are transparently redirected to the process-scoped overrides instead of the
shared store.

## Done

After steps 1–4 (plus 5–7 as needed), your app is on Bandera with the same
behavior — and with all configuration now resolved at runtime.
