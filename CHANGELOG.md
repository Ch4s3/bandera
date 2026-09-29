# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Multiple instances: run several isolated flag sets in one VM (e.g. one per
  app in an umbrella). Define a facade module with `use Bandera, otp_app: ...`,
  or start an unnamed instance with `{Bandera, name: ..., ...}`; every public
  `Bandera` function accepts an `instance:` option (default the default
  instance). See the new [Running Multiple Instances guide](guides/multiple_instances_guide.md).
- Per-instance storage isolation: the Ecto adapter accepts its own
  `ecto_table_name` and/or Postgres `prefix`, and `Bandera.Ecto.Migrations`'
  functions accept matching `:table`/`:usage_table`/`:prefix` options. An
  instance whose storage (database, prefix, and table — the database identified
  by host, port, and name, whichever repo module points at it) is already claimed by
  another running instance refuses to start (reason
  `{:storage_conflict, id, other_instance}`).
- The Redis persistence adapter automatically namespaces keys per instance, so
  several instances can share one Redis connection without colliding.
- Cache-bust notifications publish on a per-instance channel/topic
  (`"bandera:changes"` for the default instance, `"bandera:{MyApp.Flags}:changes"`
  for a named one).
- `Bandera.Usage` can track a named instance (`{Bandera.Usage, instance: ...}`),
  with its own Ecto usage table via `usage_table_name`.
- `bandera_dashboard/2` accepts `instance:` to mount a dashboard bound to a
  named instance; several dashboards can be mounted in one router.
- `mix bandera.flags` accepts `--instance` to target a named instance.
- `use Bandera, defaults: [...]` lets an embeddable library ship its
  instance's settings (lowest precedence, below application env and explicit
  child options), so a host overrides only what it needs instead of mirroring
  the library's config.
- `Bandera.Test`/`Bandera.Store.ProcessScoped` support testing a named
  instance: `use Bandera.Test, instance: MyApp.Flags`, and the fully-qualified
  helpers accept `instance:`.
- `:telemetry` event metadata and `%Bandera.Audit.Event{}` now carry the
  `instance` the call ran against.

### Changed

- The `Bandera.Store`, `Bandera.Store.Persistent`, and `Bandera.Notifications`
  behaviours are now config-first (their callbacks take a `%Bandera.Config{}`).
  Custom modules implementing only the old, config-less callbacks keep working
  at runtime ("legacy"), but if they declare `@behaviour` they now get compile
  warnings (each new callback reported as not implemented, each `@impl` on an
  old callback reported as unknown), which fail `--warnings-as-errors` builds.
  Migrate them to the config-first callbacks, or drop `@behaviour`/`@impl`.
  The built-in stores, adapters, and notifiers keep their old direct-call
  arities (e.g. `Memory.put(:flag, gate)`) for the default instance.
- The dashboard's `stale_older_than` setting is read from the instance's
  cached config; changing it with `Application.put_env/3` at runtime has no
  effect until `Bandera.reload_config/1` is called for that instance.
- `Bandera.Config.snapshot/0` returns a `%Bandera.Config{}` struct (it still
  supports `snapshot()[:key]` access).
- `Bandera.Supervisor` now supervises `Bandera.Registry` and, with
  `start_on_boot`, the default instance's own (internal) supervisor, instead of the cache, persistence, and notifier processes directly. Their
  registered names are unchanged.

### Fixed

- Usage history now exposes explicit readiness, retries its initial Ecto load
  independently of the flush interval, and keeps the dashboard from showing
  transient "never evaluated" warnings while persisted history is loading.
- Usage timestamps are monotonic across nodes, and periodic flushes merge
  persisted evaluations back into each node's ETS table.

## [0.5.0] - 2026-07-14

### Added

- Dashboard: grant/deny toggle for actor and group gates in expanded flag rows.
- `Bandera.Usage` now self-attaches its telemetry handler on `init/1` and
  detaches on `terminate/2` — no manual `attach/0` call is needed at boot.
- Usage history is persisted to the database so stale-flag detection survives
  node restarts.
- `auto_create: true` config option: when `enabled?` is called for an unknown
  flag, Bandera creates it as disabled rather than failing. Store errors during
  auto-create are logged instead of silently dropped.
- `Bandera.Dashboard.Similarity`: pure helper that detects flag names that look
  like potential duplicates (edit-distance / prefix heuristics).
- Dashboard: similarity-warning section surfaces potentially duplicate flag
  names using `Bandera.Dashboard.Similarity`.
- Dashboard: Create Flag form with name validation and a length cap.
- Dashboard: sortable table view with inline gate editor.
- Dashboard: card view icons, full-name subtitle, and stale indicator per flag.
- Dashboard: `handle_params`-driven view/grouped/sort state; new theme roles for
  table controls (`Bandera.Dashboard.Theme`).
- `Bandera.Dashboard.Stale`: isolated helper module for stale-detection logic.

### Changed

- Usage persistence simplified: dirty-tracking and the `inserted_at` column have
  been dropped.

### Fixed

- Boolean gate `put/2` now upserts atomically under concurrent writes —
  eliminates a race where two simultaneous toggles could leave the gate
  inconsistent.
- `Bandera.Usage`: corrected Dialyzer contract for the `set` callback.
- Stale detection: flags the tracker has never observed are not considered stale
  until the tracker itself has been running long enough to have seen them.
- Dashboard nav links resolve correctly when the router is mounted at a path
  other than `/flags`.

## [0.4.0] - 2026-06-01

### Added

- `Bandera.Ecto.Migrations.fix_fun_with_flags_boolean_gates/0`: one-time cleanup
  migration helper that normalises duplicate boolean gate rows left by a
  FunWithFlags-to-Bandera migration. Safe to run on a database that has already
  been fully migrated — it finds nothing to change.
- `mix bandera.gen.fix_fun_with_flags_migration`: scaffolds the cleanup migration
  file in one command, then you run `mix ecto.migrate`.

### Fixed

- Ecto store: boolean gate `put/2` now deletes any existing boolean row before
  inserting, regardless of the stored `target` value. Previously, migrating from
  FunWithFlags (which used `target = "boolean"`) left a stale row alongside
  Bandera's `target = "_bandera_none"` row because the upsert conflict key is
  `(flag_name, gate_type, target)`. The symptom was a dashboard toggle that
  showed "on" while the summary showed "off", with the toggle appearing to do
  nothing.

## [0.3.0] - 2026-05-23

### Added

- Multivariate flags: `Bandera.variant/2` and `put_variants/3` for stable
  per-actor N-way allocation. Bucketing uses a weighted SHA-256 hash — the same
  actor always sees the same variant across nodes and restarts.
- Ecto schema v2: a nullable `value` column stores variant gate payloads.
  `Bandera.Ecto.Migrations.upgrade_v2/0` migrates an existing table; new
  installs get the column automatically via `up/0`.
- Context-based targeting rules: `enable(flag, when: constraints)` and a
  `:context` map on `enabled?/2`. Supported operators: `:eq`, `:neq`, `:in`,
  `:not_in`, `:contains`, `:gt`, `:gte`, `:lt`, `:lte`, `:matches` (regex).
- Reusable segments: `put_segment/2` stores a named constraint set;
  `enable(flag, for_segment: name)` references it. Segment rules are expanded
  at evaluation time so changing a segment immediately affects every flag that
  uses it.
- Flag prerequisites: `enable(flag, requires: other_flag)` requires another
  flag to be enabled (or disabled with `{:flag, false}`) before the dependent
  flag can turn on. Dependency cycles and missing parents fail closed.
- Scheduled activation: `enable(flag, schedule: {start, stop})` enables a flag
  only inside an ISO-8601 UTC time window. Either bound may be `nil` for an
  open-ended start or end. Malformed windows fail closed.
- Audit log: `Bandera.Audit.attach/2` and `detach/1` register callbacks that
  receive a `%Bandera.Audit.Event{}` on every write. Pass `:by` to `enable/2`,
  `disable/2`, and `clear/2` to record who made the change.
- Stale flag tracking: start `Bandera.Usage` in your supervision tree and call
  `attach/0` at boot; then use `Bandera.stale_flags/1` or
  `mix bandera.flags --stale [--older-than N]` to find flags not evaluated in
  the last N days (default 30).
- Dashboard: inline editors for variant, rule-constraint, segment, prerequisite,
  and schedule gates in the expanded flag row.
- Dashboard: per-gate-type summaries shown in collapsed flag rows.
- `enabled?/2` `:default` option: pass `default: true` to fail open when the
  store is unreachable (the default behaviour remains fail closed).
- Symmetric `clear/2` options for variant, rule, segment, prerequisite, and
  schedule gates — matching the corresponding `enable/2` options.

### Changed

- Re-added `jason` as a direct dependency (required for variant gate JSON
  serialization in Ecto and Redis stores). It was dropped in 0.2.0 in favour of
  Elixir's built-in `JSON` module, but structured gate payloads need encoder
  options not available in the standard library.

### Fixed

- `stale_flags/1`: negative window values are clamped to zero.
- Telemetry: audit and usage handlers that raise are caught; they no longer
  crash the telemetry pipeline.
- Stores: JSON deserialization of unknown gate types now fails softly instead of
  crashing; prerequisite flag names are bound as atoms at load time.
- Prerequisites: resolution is memoized per `enabled?` call; cycles and unknown
  parents fail closed rather than looping.
- Targeting: empty rule sets now fail closed instead of granting access to all
  callers.
- Variant weights: negative and non-numeric weight values are rejected at write
  time.
- Constraint evaluation: comparisons are numeric-aware when both sides are
  numbers; compiled regexes are cached per constraint.

## [0.2.0] - 2026-05-22

### Added

- Phoenix LiveView flag dashboard (`Bandera.Dashboard.Router` and
  `Bandera.Dashboard.FlagsLive`): grouped flags with state summaries, live
  search filtering, row expand/collapse, boolean toggling, actor and group
  gate management, percentage set/clear, and clearing a whole flag.
- Cross-node live refresh: the dashboard updates in real time when flags
  change on other nodes, via Phoenix.PubSub.
- Themeable dashboard UI that works standalone or with daisyUI, including a
  switch-style boolean toggle and assorted UX polish (`Bandera.Dashboard.Theme`).
- Name-prefix flag grouping with a runtime-configurable `:group_separator`.
- Dev-only local dashboard preview server (`dev/preview.exs`).

### Changed

- Use Elixir's built-in `JSON` module instead of `jason`; the `jason`
  dependency has been dropped.
- Require Elixir `~> 1.18`.

## [0.1.0]

Initial release.

### Added

- Runtime-configured feature flags with the full gate model: boolean, actor,
  group, percentage-of-time, and percentage-of-actors.
- Public API: `Bandera.enabled?/2`, `enable/2`, `disable/2`, `clear/2`,
  `get_flag/1`, `all_flags/0`, `all_flag_names/0`, and `reload_config/0`.
- Persistence adapters: in-memory (default), Ecto, and Redis.
- Two-level store with an ETS cache and cross-node cache-busting notifications
  (Redis PubSub and Phoenix.PubSub adapters).
- Async-safe, process-scoped test layer (`Bandera.Test`) backed by
  NimbleOwnership.
- `:telemetry` events for reads, writes, and the persistence layer.

[Unreleased]: https://github.com/ch4s3/bandera/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/ch4s3/bandera/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/ch4s3/bandera/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/ch4s3/bandera/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/ch4s3/bandera/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/ch4s3/bandera/releases/tag/v0.1.0
