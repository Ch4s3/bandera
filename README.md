# Bandera

[![Hex.pm](https://img.shields.io/hexpm/v/bandera.svg)](https://hex.pm/packages/bandera)
[![HexDocs](https://img.shields.io/badge/hexdocs-documentation-B1A5EE)](https://hexdocs.pm/bandera)
[![GitHub Actions](https://github.com/ch4s3/bandera/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/ch4s3/bandera/actions)

Feature flags for Elixir, configured **entirely at runtime**, with an
**async-safe test layer**.

Bandera supports the full gate model — boolean, actor, group, and percentage
rollouts — backed by in-memory, Ecto, or Redis storage, with an ETS cache and
cross-node cache-busting notifications.

## Why Bandera?

Bandera exists to fix two specific, recurring pain points with feature flags in
Elixir:

**1. Runtime config — no recompilation.** Most flag libraries read some settings
through `Application.compile_env/3`, which bakes them into compiled artifacts.
Changing a value (or even building in a different environment) then forces a
recompile, which is slow and a frequent source of CI/release surprises. It also
collides with releases: `mix release` records every `compile_env` value and runs
a `:validate_compile_env` check at boot, so if `config/runtime.exs` sets a key
that was read at compile time, the release **refuses to start** with a
"different value set ... during runtime compared to compile time" error. Bandera
uses **zero** `compile_env` — every setting (cache on/off, TTL, persistence
adapter, Ecto table name, notifications) is read from `Application.get_env/3` at
runtime. There is nothing for `:validate_compile_env` to reject: you can put
config in `config/runtime.exs`, change it without a recompile, and call
`Bandera.reload_config/0` to apply it live. Hot-path reads stay fast because the
resolved config is cached in `:persistent_term`.

**2. Async-safe testing — no global bleed or deadlocks.** Flag state is normally
global (shared ETS or a database row), so toggling a flag in one test leaks into
others. That forces flag tests to run `async: false`, and writing flags inside
the Ecto SQL sandbox can deadlock. Bandera ships a **process-scoped test layer**:
overrides are scoped to the test process (and its spawned tasks), so tests run
`async: true` without interfering, never touch the database, and clean up
automatically when the test process exits. See [Testing](#testing).

## Installation

Add `bandera` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:bandera, "~> 0.1.0"}
  ]
end
```

Then fetch it:

```bash
mix deps.get
```

Out of the box Bandera uses an in-memory (ETS) store, so it works with no
further setup for development and single-node use. The persistence and
notification backends are optional dependencies — add only the ones you use:

```elixir
{:ecto_sql, "~> 3.10"},        # Ecto persistence (plus a DB driver, e.g. :postgrex)
{:redix, "~> 1.1"},            # Redis persistence and/or Redis PubSub notifications
{:phoenix_pubsub, "~> 2.1"},   # Phoenix.PubSub cross-node notifications
{:nimble_ownership, "~> 1.0", only: :test}  # required for the test layer
```

## Configuration

All configuration is read at runtime, so you can place it in
`config/runtime.exs` (or any config file). Everything has a default; this is
only needed to change a backend.

```elixir
config :bandera,
  cache: [enabled: true, ttl: 900],
  persistence: [
    adapter: Bandera.Store.Persistent.Ecto,
    repo: MyApp.Repo,
    ecto_table_name: "bandera_flags"
  ],
  cache_bust_notifications: [
    enabled: true,
    adapter: Bandera.Notifications.PhoenixPubSub,
    client: MyApp.PubSub
  ]
```

Defaults if you configure nothing: in-memory store, cache on (900s TTL),
notifications off. Call `Bandera.reload_config/0` to re-read config at runtime.

### Using the Ecto store

If you choose the Ecto adapter, create the flags table with a migration:

```elixir
defmodule MyApp.Repo.Migrations.CreateBanderaFlags do
  use Ecto.Migration

  def up, do: Bandera.Ecto.Migrations.up()
  def down, do: Bandera.Ecto.Migrations.down()
end
```

The table name is read from your runtime config (default `"bandera_flags"`).

## Usage

Once installed, the whole API lives on the `Bandera` module.

```elixir
# Simple on/off
Bandera.enable(:checkout)          #=> {:ok, true}
Bandera.enabled?(:checkout)        #=> true
Bandera.disable(:checkout)         #=> {:ok, false}

# Per actor — pass `for:` to check
Bandera.enable(:beta, for_actor: "user-1")
Bandera.enabled?(:beta, for: "user-1")   #=> true
Bandera.enabled?(:beta, for: "user-2")   #=> false

# Per group
Bandera.enable(:beta, for_group: :staff)
Bandera.enabled?(:beta, for: %{groups: [:staff]})  #=> true

# Percentage rollout (ratio between 0.0 and 1.0)
Bandera.enable(:gradual, for_percentage_of: {:actors, 0.25})
Bandera.enable(:gradual, for_percentage_of: {:time, 0.10})

# Remove gates / introspect
Bandera.clear(:checkout)           #=> :ok   (removes the whole flag)
Bandera.clear(:beta, for_actor: "user-1")
Bandera.all_flag_names()           #=> {:ok, [:beta]}
Bandera.get_flag(:beta)            #=> {:ok, %Bandera.Flag{...}}
```

`enabled?/2` always returns a boolean — a missing flag (or a store error,
which is logged) resolves to `false`.

### Actors and groups

An "actor" is anything you can identify with a stable string id, and a "group"
is membership any item can belong to. Bandera ships implementations for
binaries, integers, and maps with an `:id` / `:groups` key. For your own
structs, implement the protocols:

```elixir
defimpl Bandera.Actor, for: MyApp.User do
  def id(user), do: "user:#{user.id}"
end

defimpl Bandera.Group, for: MyApp.User do
  def in?(user, group_name), do: group_name in user.roles
end
```

## Testing

Bandera's test layer scopes flag overrides to the test process (and its
spawned tasks), so tests can run `async: true` without interfering with each
other and without touching the database.

```elixir
# config/test.exs
config :bandera, store: Bandera.Store.ProcessScoped

# test/test_helper.exs
Bandera.Test.start()
```

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

Overrides are cleaned up automatically when the test process exits.

## Telemetry

Bandera emits `:telemetry` events for reads (`[:bandera, :enabled?]`), writes
(`[:bandera, :enable | :disable | :clear]`), and the persistence layer. Attach
your own handlers to measure flag usage and store latency.

## Documentation

Generate docs locally with [ExDoc](https://github.com/elixir-lang/ex_doc):

```bash
mix docs
```

Once published, the docs will be at <https://hexdocs.pm/bandera>.
