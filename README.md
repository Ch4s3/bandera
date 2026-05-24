# Bandera

[![Hex.pm](https://img.shields.io/hexpm/v/bandera.svg)](https://hex.pm/packages/bandera)
[![HexDocs](https://img.shields.io/badge/hexdocs-documentation-B1A5EE)](https://hexdocs.pm/bandera)
[![GitHub Actions](https://github.com/ch4s3/bandera/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/ch4s3/bandera/actions)
[![Coverage Status](https://coveralls.io/repos/github/Ch4s3/bandera/badge.svg?branch=main)](https://coveralls.io/github/Ch4s3/bandera?branch=main)

Feature flags for Elixir with **multivariate variants, data-defined targeting,
and time-window scheduling** — configured **entirely at runtime**, with an
**async-safe test layer**.

Beyond the usual boolean/actor/group/percentage gates, Bandera adds N-way variant
flags, attribute-based targeting rules with reusable segments, flag prerequisites,
and scheduled activation windows — all stored as data, backed by in-memory, Ecto, or
Redis storage, with an ETS cache and cross-node cache-busting notifications.

## Why Bandera?

Most Elixir flag libraries cover boolean, actor, group, and percentage rollouts.
Bandera does all of those — but it exists for the harder cases, and three
capabilities are first-class here:

**1. Multivariate flags, not just on/off.** Serve one of N named variants,
weighted and sticky per actor (the same user always sees the same variant). Built
for A/B/n experiments and gradual variant ramps, not only kill switches. See
[Multivariate flags](#multivariate-flags).

**2. Data-defined targeting that changes without a deploy.** Target on arbitrary
attributes with a rich operator set (`:eq`, `:in`, `:gt`, `:matches`, …) through an
evaluation context, package them into reusable named **segments**, and gate flags on
other flags with **prerequisites** — all stored as data. Change *who* is targeted by
writing a row, not shipping code. See
[Targeting rules and segments](#targeting-rules-and-segments).

**3. Scheduling — flags that flip themselves.** Activate a flag inside an ISO-8601
time window (UTC) so launches and sunsets happen on schedule, instead of someone
toggling a switch at midnight. See [Scheduling](#scheduling).

And two foundations it's built to get right — the ones most flag systems get wrong:

**Runtime config, no recompilation.** Bandera reads every setting at runtime
through `Application.get_env/3` and never touches `Application.compile_env/3`.
Compile-time config gets baked into artifacts: change a value and you recompile,
and `mix release`'s `:validate_compile_env` check refuses to boot when
`config/runtime.exs` overrides a compile-time key. Here, cache, TTL, persistence
adapter, Ecto table name, and notifications all live in `config/runtime.exs`, and
`Bandera.reload_config/0` applies changes live. Resolved config is cached in
`:persistent_term`, so hot-path reads stay fast.

**Async-safe testing, no global bleed or deadlocks.** Flag state is normally
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
notification backends are optional dependencies; add only the ones you use:

```elixir
{:ecto_sql, "~> 3.10"},        # Ecto persistence (plus a DB driver: :postgrex or :ecto_sqlite3)
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

The Ecto adapter is backend-agnostic: it uses only standard column types and
binds the table at runtime, with no database-specific SQL. It works with any
Ecto SQL database — Postgres (via `:postgrex`) or SQLite (via `:ecto_sqlite3`).
SQLite is the backend Bandera's own test suite runs against.

## Usage

Once installed, the whole API lives on the `Bandera` module.

```elixir
# Simple on/off
Bandera.enable(:checkout)          #=> {:ok, true}
Bandera.enabled?(:checkout)        #=> true
Bandera.disable(:checkout)         #=> {:ok, false}

# Per actor (pass `for:` to check)
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

`enabled?/2` always returns a boolean. A missing flag (or a store error,
which is logged) resolves to `false`.

### Actors and groups

An actor is anything with a stable string id; a group is a named bucket an actor
can belong to. Bandera ships implementations for binaries, integers, and maps
(`:id` / `:groups` keys). For your own structs, implement the protocols:

```elixir
defimpl Bandera.Actor, for: MyApp.User do
  def id(user), do: "user:#{user.id}"
end

defimpl Bandera.Group, for: MyApp.User do
  def in?(user, group_name), do: group_name in user.roles
end
```

## Multivariate flags

Instead of a binary on/off, a flag can return one of N named variants. Actors
are assigned a variant by a stable SHA-256 hash (same actor + flag → same
variant across nodes and restarts), weighted proportionally:

```elixir
# Create a 50/50 A/B test
Bandera.put_variants(:hero_cta, %{"control" => 1, "treatment" => 1})

# Resolve which variant the current user sees
variant = Bandera.variant(:hero_cta, for: current_user)
# => "control" or "treatment", same value for the same user every time

# Fallback when the flag is missing or has no variant gate
Bandera.variant(:hero_cta, default: "control")

# Weighted split: 10% treatment, 90% control
Bandera.put_variants(:checkout, %{"control" => 9, "new_flow" => 1})
```

`variant/2` returns `nil` (or `options[:default]`) when the flag does not exist,
has no variant gate, or no `for:` actor is given (including `for: nil`). The same
stable SHA-256 score used by `percentage_of_actors` gates determines an actor's
bucket — deterministic per actor+flag pair, different across flags.

## Targeting rules and segments

Flags can target arbitrary attributes in an **evaluation context** map — without
deploying code. Rules are stored as data in the flags table.

### Context-based rules

Pass a `context:` map to `enabled?/2` and use `enable(flag, when: constraints)`
to define which context values grant access:

```elixir
# Enable only for premium US users
Bandera.enable(:new_billing,
  when: [
    {"plan", :eq, "premium"},
    {"country", :eq, "US"}
  ]
)

# All constraints must match (AND semantics)
Bandera.enabled?(:new_billing, context: %{"plan" => "premium", "country" => "US"})
#=> true

Bandera.enabled?(:new_billing, context: %{"plan" => "free", "country" => "US"})
#=> false
```

Supported operators: `:eq`, `:neq`, `:in`, `:not_in`, `:contains`, `:gt`,
`:gte`, `:lt`, `:lte`, `:matches` (regex).

### Reusable segments

Define a **segment** once and reference it from many flags:

```elixir
# Store a named set of constraints
Bandera.put_segment(:premium_us, [
  {"plan", :eq, "premium"},
  {"country", :eq, "US"}
])

# Enable flags by referencing the segment
Bandera.enable(:new_billing, for_segment: :premium_us)
Bandera.enable(:advanced_reports, for_segment: :premium_us)

# Check is the same — pass context:
Bandera.enabled?(:new_billing, context: %{"plan" => "premium", "country" => "US"})
#=> true
```

Segment constraints are expanded at evaluation time; changing a segment's rules
automatically affects every flag that references it.

### Evaluation precedence

When `:for` and `:context` are both present, precedence is:
actor gates → group gates → rule/segment gates → boolean/schedule gates → percentage
gates.

### Migrating an existing Ecto install (schema v2)

If you already have the Bandera flags table and want to add variant support,
run this one-time helper from a new migration:

```elixir
defmodule MyApp.Repo.Migrations.BanderaSchemaV2 do
  use Ecto.Migration

  def up, do: Bandera.Ecto.Migrations.upgrade_v2()
  def down, do: :ok
end
```

`upgrade_v2/0` adds the nullable `value` column to an existing table with a plain
`add/2` (so it also works on adapters such as SQLite3 that reject conditional column
additions); run it once from a versioned migration. New installs calling
`Bandera.Ecto.Migrations.up()` get the column automatically.

## Prerequisites

A flag can require another flag to be in a given state before it's allowed to turn
on. Prerequisites only *veto* — the dependent flag still needs its own granting gate.

```elixir
Bandera.enable(:parent_feature)

Bandera.enable(:child_feature, requires: :parent_feature)
Bandera.enable(:child_feature)            # the child's own grant

Bandera.enabled?(:child_feature)          # true only while :parent_feature is enabled
```

Require a parent to be *off* with `requires: {:parent, false}`. Dependency cycles and
missing parents resolve to `false` rather than looping.

## Scheduling

A schedule gate enables a flag only inside an ISO-8601 time window, evaluated in UTC.
Either bound may be `nil` for an open-ended start or end.

```elixir
# Active only during the launch window
Bandera.enable(:black_friday,
  schedule: {"2026-11-27T00:00:00Z", "2026-11-30T23:59:59Z"})

Bandera.enabled?(:black_friday)   # true only inside the window

# Open-ended: on from a start time, with no end
Bandera.enable(:new_nav, schedule: {"2026-06-01T00:00:00Z", nil})
```

A malformed stored window fails closed (the flag is simply not enabled by the
schedule). Schedule gates take part in the boolean fallback, so they combine with
the other gate types just as the boolean gate does.

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

## Fail-open default

By default `enabled?/2` returns `false` when the store is unreachable (the
error is logged). Pass `default: true` to fail open instead:

```elixir
# Returns true if the store is down, false if the flag is simply off.
Bandera.enabled?(:checkout, default: true)

# Works with per-actor checks too.
Bandera.enabled?(:beta, for: current_user, default: true)
```

## Audit log

Bandera includes an opt-in audit hook that turns the built-in write telemetry
into structured change events. Attach it once at startup with a callback:

```elixir
# In your application start/2 or a supervision child:
Bandera.Audit.attach(:my_audit, fn event ->
  MyApp.AuditLog.insert!(%{
    action: event.action,
    flag: event.flag_name,
    actor: event.actor,
    at: event.at
  })
end)
```

The callback receives a `%Bandera.Audit.Event{}` on every `enable/2`,
`disable/2`, or `clear/2` call. Pass `:by` to the write functions to record
who made the change:

```elixir
Bandera.enable(:checkout, by: current_user.email)
Bandera.disable(:beta, for_actor: %{id: 1}, by: "admin@example.com")
```

Call `Bandera.Audit.detach/1` with the same handler id to stop receiving events:

```elixir
Bandera.Audit.detach(:my_audit)
```

## Stale flags

Bandera can tell you which flags haven't been evaluated recently, so you can
prune flags that are no longer in use.

Start `Bandera.Usage` in your supervision tree and call `attach/0` once at
boot:

```elixir
# In your application start/2:
children = [
  # ... your other children ...
  Bandera.Usage
]
Supervisor.start_link(children, strategy: :one_for_one)

# After the supervisor starts:
Bandera.Usage.attach()
```

Then query stale flags from IEx or a scheduled job:

```elixir
# Flags not evaluated in the past 30 days (default):
Bandera.stale_flags()

# Custom window:
Bandera.stale_flags(older_than: 60)
```

Or use the Mix task from the command line:

```bash
# List all flags:
mix bandera.flags

# List stale flags (not evaluated in 30 days):
mix bandera.flags --stale

# Custom window:
mix bandera.flags --stale --older-than 60
```

`Bandera.Usage` is opt-in: nothing breaks when it is not started —
`stale_flags/1` simply treats every flag as stale.

## Telemetry

Bandera emits `:telemetry` events for reads (`[:bandera, :enabled?]`), writes
(`[:bandera, :enable | :disable | :clear]`), and the persistence layer. Attach
your own handlers to measure flag usage and store latency.

## Dashboard (optional)

Bandera includes an optional LiveView dashboard to browse and manage flags —
grouped, searchable, with full per-gate control. It ships in the core library and
activates only when your app depends on `phoenix_live_view`. It ships no
JavaScript and needs no asset-pipeline changes — it inherits your layout and runs
on your existing LiveView socket. Mount it behind your own admin auth:

    import Bandera.Dashboard.Router

    scope "/admin" do
      pipe_through [:browser, :require_admin]
      bandera_dashboard "/flags"
    end

See the [Dashboard guide](guides/dashboard_guide.md) for details.

## Documentation

In-depth guides:

- [Feature Guide](guides/features_guide.md) — multivariate flags, targeting rules,
  segments, prerequisites, scheduling, audit log, and stale-flag tooling
- [Using Bandera with Phoenix LiveView](guides/phoenix_liveview_guide.md)
- [Flag Dashboard (LiveView UI)](guides/dashboard_guide.md)
- [Migration from fun_with_flags](guides/migration_guide.md)

Generate docs locally with [ExDoc](https://github.com/elixir-lang/ex_doc):

```bash
mix docs
```

Once published, the docs will be at <https://hexdocs.pm/bandera>.
