# Feature Guide

A short, practical tour of Bandera's targeting, rollout, and operations features.
Every example assumes Bandera is configured with a store (see the README).
`enable/2`, `disable/2`, and `clear/2` accept an optional `by:` identity
(see [Audit log](#audit-log)).

- [Fail-open default](#fail-open-default)
- [Audit log](#audit-log)
- [Multivariate flags](#multivariate-flags)
- [Targeting rules and context](#targeting-rules-and-context)
- [Reusable segments](#reusable-segments)
- [Prerequisites](#prerequisites)
- [Scheduling](#scheduling)
- [Finding stale flags](#finding-stale-flags)

## Fail-open default

`enabled?/2` returns `false` if the store is unreachable. Pass `default: true` to
**fail open** for a specific call instead — useful for flags that should stay on if
your flag backend has a blip:

```elixir
# returns true if the store errors, instead of the global false
Bandera.enabled?(:checkout, default: true)

Bandera.enabled?(:checkout, for: current_user, default: true)
```

The default only applies when the lookup *fails*; a flag that simply isn't set is
still `false`.

## Audit log

`Bandera.Audit` turns Bandera's write telemetry into structured change events. It's
opt-in: attach a handler once at boot and forward events wherever you like.

```elixir
Bandera.Audit.attach(:my_audit, fn event ->
  MyApp.AuditLog.insert!(event)
end)
```

Each `%Bandera.Audit.Event{}` carries `:action` (`:enable | :disable | :clear`),
`:flag_name`, `:options`, `:result`, `:actor`, and `:at` (a `DateTime`). Record *who*
made a change by passing `by:` to any write:

```elixir
Bandera.enable(:promo, by: "admin@example.com")
# => %Bandera.Audit.Event{action: :enable, flag_name: :promo, actor: "admin@example.com", ...}
```

Detach with `Bandera.Audit.detach(:my_audit)`.

## Multivariate flags

Instead of on/off, a flag can return one of N named variants, stable per actor
(the same actor always lands in the same variant for a given flag). Weights are
relative.

```elixir
Bandera.put_variants(:checkout_button, %{"blue" => 1, "green" => 1, "red" => 2})

case Bandera.variant(:checkout_button, for: current_user) do
  "blue"  -> ...
  "green" -> ...
  "red"   -> ...
end

# No variant gate / no actor / store error -> the :default (nil if unset)
Bandera.variant(:checkout_button, for: current_user, default: "blue")
```

A weight of `0` means a variant is never served (handy for ramping a variant down to
nothing without removing it).

## Targeting rules and context

Pass a `context` map (`%{"attribute" => value}`) and gate the flag on it with
`enable(when:)`. A rule matches only when **all** of its constraints hold.

```elixir
Bandera.enable(:eu_pricing, when: [
  {"country", :in, ["DE", "FR", "ES"]},
  {"plan", :eq, "premium"}
])

Bandera.enabled?(:eu_pricing, context: %{"country" => "FR", "plan" => "premium"})
# => true
```

Supported operators:

| Operator | Meaning |
|----------|---------|
| `:eq`, `:neq` | equal / not equal |
| `:in`, `:not_in` | membership in a list |
| `:contains` | substring (strings) |
| `:gt`, `:gte`, `:lt`, `:lte` | ordering (numbers or strings) |
| `:matches` | unanchored regex match — `"admin"` matches `"superadmin"`; use `^`/`$` for full-string; an invalid pattern never matches |

A missing context attribute never matches. Rule gates compose with the usual
actor/group/boolean/percentage gates.

## Reusable segments

A segment is a named, reusable set of constraints. Define it once, then point any
number of flags at it; editing the segment updates every flag that uses it.

```elixir
Bandera.put_segment(:premium_us, [
  {"plan", :eq, "premium"},
  {"country", :eq, "US"}
])

Bandera.enable(:new_billing, for_segment: :premium_us)

Bandera.enabled?(:new_billing, context: %{"plan" => "premium", "country" => "US"})
# => true
```

Segments are expanded at evaluation time against the current context.

## Prerequisites

A flag can require another flag to be in a particular state. Prerequisites only
*veto* — the child still needs its own granting gate.

```elixir
Bandera.enable(:parent_feature)

Bandera.enable(:child_feature, requires: :parent_feature)
Bandera.enable(:child_feature)            # the child's own grant

Bandera.enabled?(:child_feature)          # true only while :parent_feature is on
```

Require a parent to be **off** with `requires: {:parent, false}`. Cycles and broken
chains resolve to `false` rather than looping.

## Scheduling

A schedule gate enables a flag only within an ISO-8601 time window (UTC). Either
bound may be `nil` for an open-ended start or end.

```elixir
Bandera.enable(:black_friday,
  schedule: {"2026-11-27T00:00:00Z", "2026-11-30T23:59:59Z"})

Bandera.enabled?(:black_friday)   # true only inside the window
```

Comparisons are always in UTC; a malformed stored window fails closed (the flag is
simply not enabled by the schedule).

## Finding stale flags

`Bandera.Usage` records, in ETS, the last time each flag was evaluated. Start it in
your supervision tree and attach it once at boot:

```elixir
children = [
  # ...
  Bandera.Usage
]

# after the tree is up:
Bandera.Usage.attach()
```

Then list flags that haven't been evaluated recently (or ever):

```elixir
Bandera.stale_flags(older_than: 30)   # flags untouched for 30+ days
```

Or from the command line:

```bash
mix bandera.flags             # list all flags
mix bandera.flags --stale --older-than 30
```

`Bandera.Usage` is entirely opt-in: if it isn't running, `stale_flags/1` treats every
flag as never-evaluated and the mix task prints a warning.
