defmodule NoDefaultInstanceFallbackTest do
  @moduledoc """
  Guards multi-instance isolation. Bandera's own code must always act on an
  explicit `%Bandera.Config{}` (threaded down from the public API's `instance:`
  option), never on the default instance by accident: such a slip passes every
  single-instance test but silently mixes instances in production.

  Each rule below is a default-instance shortcut, allowed only in the listed
  files (the backward-compatibility wrappers that define it). Comment lines and
  doctest lines are ignored.
  """
  use ExUnit.Case, async: true

  @rules [
    {"zero-arity Bandera.Config accessor (reads the default instance)",
     ~r/Config\.(store|cache_enabled\?|cache_ttl|persistence_adapter|persistence|ecto_table_name|notifications_enabled\?|notifications_adapter|notifications|group_separator|theme|snapshot)\(\)/,
     ["lib/bandera/config.ex"]},
    {"Bandera.Config.get/0 (the default instance's config)", ~r/(?<!\|> )Config\.get\(\)/,
     [
       "lib/bandera/config.ex",
       "lib/bandera/store.ex",
       "lib/bandera/store/cache.ex",
       "lib/bandera/notifications.ex",
       "lib/bandera/usage/ecto.ex",
       # the pre-instance arities kept for callers outside Bandera
       "lib/bandera/store/two_level.ex",
       "lib/bandera/store/process_scoped.ex",
       "lib/bandera/store/persistent/memory.ex",
       "lib/bandera/store/persistent/ecto.ex",
       "lib/bandera/store/persistent/redis.ex",
       "lib/bandera/notifications/phoenix_pubsub.ex",
       "lib/bandera/notifications/redis.ex"
     ]},
    # Bandera itself reaches stores, adapters, and notifiers only through the
    # config-passing dispatch in Bandera.Store / Store.Persistent / Notifications,
    # so their default-instance compatibility arities can never be hit internally.
    {"direct call into a built-in store, adapter, or notifier",
     ~r/\b(TwoLevel|ProcessScoped|Persistent\.Memory|Persistent\.Ecto|Persistent\.Redis|Notifications\.Redis|PhoenixPubSub)\.(get|put|delete|lookup|all_flags|all_flag_names|publish_change|unique_id)\(/,
     []},
    {"Bandera.Store.active/0", ~r/Store\.active\(\)/, ["lib/bandera/store.ex"]},
    {"single-argument Bandera.Store.Cache call (the default instance's cache)",
     ~r/Cache\.(get|put|bust)\([^,()]*\)|Cache\.flush\(\)/, ["lib/bandera/store/cache.ex"]},
    {"default-instance Bandera.Usage call",
     ~r/Usage\.(ready\?|flush)\(\)|Usage\.last_evaluated\([^,()]*\)|Process\.whereis\(Bandera\.Usage\)/,
     ["lib/bandera/usage.ex"]},
    {"single-argument Bandera.Notifications.publish_change (the default instance)",
     ~r/Notifications\.publish_change\([^,()]*\)/, ["lib/bandera/notifications.ex"]},
    {"process or table registered under a fixed module name (collides across instances)",
     ~r/name: __MODULE__|@(table|conn) __MODULE__|GenServer\.call\(__MODULE__/, []},
    {"reading config :bandera directly (only the default instance's settings)",
     ~r/Application\.get_env\(:bandera\b|get_env\(:dashboard/,
     [
       "lib/bandera/config.ex",
       "lib/bandera/application.ex",
       # auto_create: the default instance keeps its historical live read.
       "lib/bandera.ex"
     ]}
  ]

  test "lib/ never falls back to the default instance" do
    offenses =
      for path <- Path.wildcard("lib/**/*.ex"),
          {line, number} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          not String.starts_with?(String.trim_leading(line), "#"),
          not String.contains?(line, "iex>"),
          {description, regex, allowed} <- @rules,
          path not in allowed,
          Regex.match?(regex, line) do
        "#{path}:#{number}: #{description}\n    #{String.trim(line)}"
      end

    assert offenses == [], "default-instance fallbacks found:\n\n" <> Enum.join(offenses, "\n")
  end
end
