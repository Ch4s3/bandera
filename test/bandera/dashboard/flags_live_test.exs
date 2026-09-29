defmodule Bandera.Dashboard.FlagsLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Bandera.Store.Cache
  alias Bandera.Store.Persistent.Memory

  @endpoint Bandera.Dashboard.TestEndpoint

  setup do
    start_supervised!(Memory)
    start_supervised!(Cache)
    Application.put_env(:bandera, :cache, enabled: true, ttl: 900)
    Application.put_env(:bandera, :persistence, adapter: Memory)
    Application.put_env(:bandera, :store, Bandera.Store.TwoLevel)
    Application.put_env(:bandera, :dashboard, group_separator: "_")
    Bandera.reload_config()

    on_exit(fn ->
      Application.delete_env(:bandera, :cache)
      Application.delete_env(:bandera, :persistence)
      Application.delete_env(:bandera, :store)
      Application.delete_env(:bandera, :dashboard)
      Bandera.reload_config()
    end)

    %{conn: build_conn()}
  end

  test "mounts and renders the dashboard heading", %{conn: conn} do
    {:ok, _live, html} = live(conn, "/flags")
    assert html =~ "Bandera"
  end

  test "renders flags grouped by name prefix", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, true} = Bandera.enable(:billing_checkout, for_percentage_of: {:actors, 0.25})
    {:ok, true} = Bandera.enable(:beta)

    {:ok, _live, html} = live(conn, "/flags")

    assert html =~ "billing"
    assert html =~ "invoices"
    assert html =~ "checkout"
    assert html =~ "25% of actors"
    assert html =~ "Ungrouped"
    assert html =~ "beta"
  end

  test "search filters the flag list", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, true} = Bandera.enable(:search_fuzzy)

    {:ok, live, _html} = live(conn, "/flags")
    html = render_change(form(live, "form[phx-change=search]"), %{"q" => "invoic"})

    assert html =~ "invoices"
    refute html =~ "fuzzy"
  end

  test "expanding a row reveals its gate editor", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, live, html} = live(conn, "/flags")
    refute html =~ "add actor"

    html = render_click(live, "toggle_row", %{"flag" => "billing_invoices"})
    assert html =~ "add actor"
    assert html =~ "add group"
    assert html =~ "Clear whole flag"
  end

  test "toggling boolean enables then disables the flag", %{conn: conn} do
    {:ok, false} = Bandera.disable(:billing_invoices)
    {:ok, live, _html} = live(conn, "/flags")

    html = render_click(live, "toggle_boolean", %{"flag" => "billing_invoices"})
    assert html =~ ">on<"
    assert Bandera.enabled?(:billing_invoices)

    html = render_click(live, "toggle_boolean", %{"flag" => "billing_invoices"})
    assert html =~ ">off<"
    refute Bandera.enabled?(:billing_invoices)
  end

  test "add and remove an actor gate", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, live, _html} = live(conn, "/flags")
    _ = render_click(live, "toggle_row", %{"flag" => "billing_invoices"})

    html = render_submit(live, "add_actor", %{"flag" => "billing_invoices", "actor" => "user-1"})
    assert html =~ "user-1"
    assert Bandera.enabled?(:billing_invoices, for: "user-1")

    html =
      render_click(live, "remove_actor", %{"flag" => "billing_invoices", "actor" => "user-1"})

    refute html =~ "user-1"
  end

  test "add and remove a group gate", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, live, _html} = live(conn, "/flags")
    _ = render_click(live, "toggle_row", %{"flag" => "billing_invoices"})

    html = render_submit(live, "add_group", %{"flag" => "billing_invoices", "group" => "beta"})
    assert html =~ "beta"
    assert Bandera.enabled?(:billing_invoices, for: %{id: 1, groups: [:beta]})

    html = render_click(live, "remove_group", %{"flag" => "billing_invoices", "group" => "beta"})
    refute html =~ ">beta<"
  end

  test "toggle_actor_gate flips an actor gate between grant and deny", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, true} = Bandera.enable(:billing_invoices, for_actor: "user-1")
    {:ok, live, _html} = live(conn, "/flags")
    _ = render_click(live, "toggle_row", %{"flag" => "billing_invoices"})

    assert Bandera.enabled?(:billing_invoices, for: "user-1")

    # Toggle to deny — gate stays, but flips to disabled.
    _ =
      render_click(live, "toggle_actor_gate", %{"flag" => "billing_invoices", "actor" => "user-1"})

    refute Bandera.enabled?(:billing_invoices, for: "user-1")
    assert actor_gate(:billing_invoices, "user-1").enabled == false

    # Toggle back to grant.
    _ =
      render_click(live, "toggle_actor_gate", %{"flag" => "billing_invoices", "actor" => "user-1"})

    assert Bandera.enabled?(:billing_invoices, for: "user-1")
    assert actor_gate(:billing_invoices, "user-1").enabled == true
  end

  test "toggle_group_gate flips a group gate between grant and deny", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices, for_group: "beta")
    {:ok, live, _html} = live(conn, "/flags")
    _ = render_click(live, "toggle_row", %{"flag" => "billing_invoices"})

    assert Bandera.enabled?(:billing_invoices, for: %{id: 1, groups: [:beta]})

    _ =
      render_click(live, "toggle_group_gate", %{"flag" => "billing_invoices", "group" => "beta"})

    refute Bandera.enabled?(:billing_invoices, for: %{id: 1, groups: [:beta]})
    assert group_gate(:billing_invoices, "beta").enabled == false

    _ =
      render_click(live, "toggle_group_gate", %{"flag" => "billing_invoices", "group" => "beta"})

    assert Bandera.enabled?(:billing_invoices, for: %{id: 1, groups: [:beta]})
    assert group_gate(:billing_invoices, "beta").enabled == true
  end

  test "a denied group gate renders with the off toggle and survives a clear", %{conn: conn} do
    {:ok, _} = Bandera.disable(:billing_invoices, for_group: "beta")
    {:ok, live, _html} = live(conn, "/flags")
    html = render_click(live, "toggle_row", %{"flag" => "billing_invoices"})

    # The deny gate is listed (not hidden) and its toggle reads "off".
    assert html =~ "beta"
    assert group_gate(:billing_invoices, "beta").enabled == false

    # remove still clears the gate entirely.
    _ = render_click(live, "remove_group", %{"flag" => "billing_invoices", "group" => "beta"})
    assert group_gate(:billing_invoices, "beta") == nil
  end

  test "set and clear a percentage gate, with validation", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, live, _html} = live(conn, "/flags")
    _ = render_click(live, "toggle_row", %{"flag" => "billing_invoices"})

    html =
      render_submit(live, "set_percentage", %{
        "flag" => "billing_invoices",
        "percent" => "25",
        "kind" => "actors"
      })

    assert html =~ "25% of actors"

    html =
      render_submit(live, "set_percentage", %{
        "flag" => "billing_invoices",
        "percent" => "0",
        "kind" => "actors"
      })

    assert html =~ "between 1 and 99"

    html = render_click(live, "clear_percentage", %{"flag" => "billing_invoices"})
    refute html =~ "% of actors"
  end

  test "clearing a flag removes it from the list", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, live, html} = live(conn, "/flags")
    assert html =~ "invoices"

    html = render_click(live, "clear_flag", %{"flag" => "billing_invoices"})
    refute html =~ "invoices"
    refute Bandera.enabled?(:billing_invoices)
  end

  test "set_percentage of time renders percent of time", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, live, _html} = live(conn, "/flags")
    _ = render_click(live, "toggle_row", %{"flag" => "billing_invoices"})

    html =
      render_submit(live, "set_percentage", %{
        "flag" => "billing_invoices",
        "percent" => "10",
        "kind" => "time"
      })

    assert html =~ "10% of time"
  end

  test "set_percentage rejects non-numeric input", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, live, _html} = live(conn, "/flags")
    _ = render_click(live, "toggle_row", %{"flag" => "billing_invoices"})

    html =
      render_submit(live, "set_percentage", %{
        "flag" => "billing_invoices",
        "percent" => "abc",
        "kind" => "actors"
      })

    assert html =~ "between 1 and 99"
  end

  test "add_actor with a blank id shows a validation error", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, live, _html} = live(conn, "/flags")
    _ = render_click(live, "toggle_row", %{"flag" => "billing_invoices"})

    html = render_submit(live, "add_actor", %{"flag" => "billing_invoices", "actor" => "   "})
    assert html =~ "Actor id can"
  end

  test "add_group with a blank name shows a validation error", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, live, _html} = live(conn, "/flags")
    _ = render_click(live, "toggle_row", %{"flag" => "billing_invoices"})

    html = render_submit(live, "add_group", %{"flag" => "billing_invoices", "group" => ""})
    assert html =~ "Group name can"
  end

  test "ignores unrelated info messages", %{conn: conn} do
    {:ok, live, _html} = live(conn, "/flags")
    send(live.pid, :some_unrelated_message)
    assert render(live) =~ "Bandera"
  end

  test "clearing an expanded flag collapses and removes it", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, live, _html} = live(conn, "/flags")
    _ = render_click(live, "toggle_row", %{"flag" => "billing_invoices"})

    html = render_click(live, "clear_flag", %{"flag" => "billing_invoices"})
    refute html =~ "invoices"
  end

  test "the add-actor input is cleared after a successful add", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, live, _html} = live(conn, "/flags")
    _ = render_click(live, "toggle_row", %{"flag" => "billing_invoices"})

    # The typed draft is reflected back to the field on change...
    html =
      live
      |> form("form[phx-change=actor_input]", %{"flag" => "billing_invoices", "actor" => "user-1"})
      |> render_change()

    assert html =~ ~s(name="actor" value="user-1")

    # ...and cleared once the add succeeds, ready for the next entry.
    html = render_submit(live, "add_actor", %{"flag" => "billing_invoices", "actor" => "user-1"})
    assert html =~ ~s(name="actor" value="")
    refute html =~ ~s(name="actor" value="user-1")
  end

  test "a failed add keeps the typed draft so it can be corrected", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, live, _html} = live(conn, "/flags")
    _ = render_click(live, "toggle_row", %{"flag" => "billing_invoices"})

    # The user has typed a draft into the group field.
    _ =
      live
      |> form("form[phx-change=group_input]", %{
        "flag" => "billing_invoices",
        "group" => "keep-me"
      })
      |> render_change()

    # A submission that fails validation must not wipe what they typed.
    html = render_submit(live, "add_group", %{"flag" => "billing_invoices", "group" => ""})
    assert html =~ "Group name can"
    assert html =~ ~s(name="group" value="keep-me")
  end

  test "a collapsed group stays collapsed across a re-render", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, live, html} = live(conn, "/flags")

    # Groups start open.
    assert html =~ ~s(class="bandera-group" open)

    # Collapsing the group drops the `open` attribute.
    html = render_click(live, "toggle_group", %{"group" => "billing"})
    refute html =~ ~s(class="bandera-group" open)

    # A later server patch (here, a search keystroke) must not snap it back open.
    html = render_change(form(live, "form[phx-change=search]"), %{"q" => ""})
    refute html =~ ~s(class="bandera-group" open)
    assert html =~ ~s(class="bandera-group">)
  end

  test "standalone theme (default) inlines the stylesheet and uses bandera- classes", %{
    conn: conn
  } do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, _live, html} = live(conn, "/flags")

    assert html =~ "<style"
    assert html =~ ~s(class="bandera-search")
    assert html =~ "bandera-row"
  end

  test "daisyui theme emits daisyUI classes and no inlined stylesheet", %{conn: conn} do
    Application.put_env(:bandera, :dashboard, group_separator: "_", theme: :daisyui)
    Bandera.reload_config()

    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, live, html} = live(conn, "/flags")

    refute html =~ "<style"
    refute html =~ "bandera-"
    assert html =~ "input input-bordered"
    assert html =~ "rounded-box"

    # The gate editor uses daisyUI classes too.
    html = render_click(live, "toggle_row", %{"flag" => "billing_invoices"})
    assert html =~ "btn btn-primary"
  end

  test "add and remove a variant gate", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, live, _html} = live(conn, "/flags")
    _ = render_click(live, "toggle_row", %{"flag" => "billing_invoices"})

    html =
      render_submit(live, "add_variant", %{
        "flag" => "billing_invoices",
        "variant" => "blue",
        "weight" => "1"
      })

    assert html =~ "variants blue 100%"
    assert Bandera.variant(:billing_invoices, for: %{id: 1}) == "blue"

    html =
      render_click(live, "remove_variant", %{"flag" => "billing_invoices", "variant" => "blue"})

    refute html =~ "variants blue"
  end

  test "add_variant rejects a non-positive weight", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, live, _html} = live(conn, "/flags")
    _ = render_click(live, "toggle_row", %{"flag" => "billing_invoices"})

    html =
      render_submit(live, "add_variant", %{
        "flag" => "billing_invoices",
        "variant" => "blue",
        "weight" => "0"
      })

    assert html =~ "positive weight"
  end

  test "add_variant rejects a blank name", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, live, _html} = live(conn, "/flags")
    _ = render_click(live, "toggle_row", %{"flag" => "billing_invoices"})

    html =
      render_submit(live, "add_variant", %{
        "flag" => "billing_invoices",
        "variant" => "   ",
        "weight" => "1"
      })

    assert html =~ "Variant needs a name"
  end

  test "add and remove a rule constraint", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, live, _html} = live(conn, "/flags")
    _ = render_click(live, "toggle_row", %{"flag" => "billing_invoices"})

    html =
      render_submit(live, "add_constraint", %{
        "flag" => "billing_invoices",
        "attribute" => "plan",
        "operator" => "eq",
        "values" => "pro"
      })

    assert html =~ "rule (1 constraint)"
    assert html =~ "plan eq pro"

    html =
      render_click(live, "remove_constraint", %{"flag" => "billing_invoices", "index" => "0"})

    refute html =~ "plan eq pro"
  end

  test "add_constraint rejects a blank attribute", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, live, _html} = live(conn, "/flags")
    _ = render_click(live, "toggle_row", %{"flag" => "billing_invoices"})

    html =
      render_submit(live, "add_constraint", %{
        "flag" => "billing_invoices",
        "attribute" => "  ",
        "operator" => "eq",
        "values" => "pro"
      })

    assert html =~ "attribute and a valid operator"
  end

  test "add and remove a segment gate", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, live, _html} = live(conn, "/flags")
    _ = render_click(live, "toggle_row", %{"flag" => "billing_invoices"})

    html =
      render_submit(live, "add_segment", %{"flag" => "billing_invoices", "segment" => "premium"})

    assert html =~ "premium"
    assert html =~ "1 segment"

    html =
      render_click(live, "remove_segment", %{"flag" => "billing_invoices", "segment" => "premium"})

    refute html =~ ">premium<"
  end

  test "add_segment with a blank name shows a validation error", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, live, _html} = live(conn, "/flags")
    _ = render_click(live, "toggle_row", %{"flag" => "billing_invoices"})

    html = render_submit(live, "add_segment", %{"flag" => "billing_invoices", "segment" => ""})
    assert html =~ "Segment name can"
  end

  test "add and remove a prerequisite gate", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, true} = Bandera.enable(:billing_parent)
    {:ok, live, _html} = live(conn, "/flags")
    _ = render_click(live, "toggle_row", %{"flag" => "billing_invoices"})

    html =
      render_submit(live, "add_prerequisite", %{
        "flag" => "billing_invoices",
        "parent" => "billing_parent",
        "required" => "on"
      })

    assert html =~ "billing_parent (must be on)"
    assert html =~ "1 prerequisite"

    html =
      render_click(live, "remove_prerequisite", %{
        "flag" => "billing_invoices",
        "parent" => "billing_parent"
      })

    refute html =~ "must be on"
  end

  test "add_prerequisite with no parent shows a validation error", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, live, _html} = live(conn, "/flags")
    _ = render_click(live, "toggle_row", %{"flag" => "billing_invoices"})

    html =
      render_submit(live, "add_prerequisite", %{
        "flag" => "billing_invoices",
        "parent" => "",
        "required" => "on"
      })

    assert html =~ "Pick a prerequisite flag"
  end

  test "set and clear a schedule gate, with validation", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, live, _html} = live(conn, "/flags")
    _ = render_click(live, "toggle_row", %{"flag" => "billing_invoices"})

    html =
      render_submit(live, "set_schedule", %{
        "flag" => "billing_invoices",
        "from" => "2026-01-01T00:00:00Z",
        "until" => "2026-06-01T00:00:00Z"
      })

    assert html =~ "scheduled 2026-01-01T00:00:00Z → 2026-06-01T00:00:00Z"
    assert html =~ ~s(name="from" value="2026-01-01T00:00:00Z")
    assert html =~ ~s(name="until" value="2026-06-01T00:00:00Z")

    html =
      render_submit(live, "set_schedule", %{
        "flag" => "billing_invoices",
        "from" => "",
        "until" => ""
      })

    assert html =~ "start or an end"

    html = render_click(live, "clear_schedule", %{"flag" => "billing_invoices"})
    refute html =~ "scheduled 2026"
  end

  test "defaults to card view with grouping on", %{conn: conn} do
    {:ok, _live, html} = live(conn, "/flags")
    assert html =~ "Table"
    assert html =~ "Group by namespace"
  end

  test "?view=table switches to table view", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, _live, html} = live(conn, "/flags?view=table")
    assert html =~ "bandera-table"
    assert html =~ "Last evaluated"
  end

  test "?grouped=false shows full flag names without group headers", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, _live, html} = live(conn, "/flags?grouped=false")
    assert html =~ "billing_invoices"
    refute html =~ "<summary"
  end

  test "view and grouping toggle links use the actual mount path, not /flags", %{conn: conn} do
    {:ok, _live, html} = live(conn, "/feature-flags")
    assert html =~ ~s(href="/feature-flags?)
    refute html =~ ~s(href="/flags?)
  end

  test "table view works when mounted at a custom path", %{conn: conn} do
    {:ok, _live, html} = live(conn, "/feature-flags?view=table")
    assert html =~ "bandera-table"
  end

  test "grouped=false works when mounted at a custom path", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, _live, html} = live(conn, "/feature-flags?grouped=false")
    assert html =~ "billing_invoices"
    refute html =~ "<summary"
  end

  test "usage_warning is shown when Bandera.Usage is not running", %{conn: conn} do
    {:ok, _live, html} = live(conn, "/flags")
    assert html =~ "Stale flag detection is unavailable"
  end

  test "GIVEN persisted usage is loading WHEN it becomes ready THEN the dashboard refreshes", %{
    conn: conn
  } do
    start_supervised!(Bandera.Usage)
    {:ok, true} = Bandera.enable(:billing_invoices)
    :sys.replace_state(Bandera.Usage, fn state -> %{state | loaded?: false} end)

    {:ok, live, html} = live(conn, "/flags")

    assert html =~ "Usage history is loading"
    refute html =~ "Never evaluated"

    old_time = DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)
    :ets.insert(Bandera.Usage, {:billing_invoices, old_time})
    :sys.replace_state(Bandera.Usage, fn state -> %{state | loaded?: true} end)

    assert eventually(fn ->
             html = render(live)
             html =~ "Stale — last seen 40d ago" and not (html =~ "Usage history is loading")
           end)
  end

  test "stale flag shows ⚠ icon when Usage is running and flag is stale", %{conn: conn} do
    start_supervised!(Bandera.Usage)
    {:ok, true} = Bandera.enable(:billing_invoices)
    old_time = DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)
    :ets.insert(Bandera.Usage, {:billing_invoices, old_time})

    {:ok, _live, html} = live(conn, "/flags")
    assert html =~ "⚠"
  end

  test "flag with schedule gate shows 📅 icon", %{conn: conn} do
    {:ok, true} =
      Bandera.enable(:billing_invoices,
        schedule: {"2026-01-01T00:00:00Z", "2027-01-01T00:00:00Z"}
      )

    {:ok, _live, html} = live(conn, "/flags")
    assert html =~ "📅"
  end

  test "flag with prerequisite gate shows 🔗 icon", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, true} = Bandera.enable(:billing_parent)
    Bandera.enable(:billing_invoices, requires: {:billing_parent, true})

    {:ok, _live, html} = live(conn, "/flags")
    assert html =~ "🔗"
  end

  test "grouped mode shows full namespaced name as subtitle", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, _live, html} = live(conn, "/flags")
    assert html =~ "billing_invoices"
  end

  test "table view shows all flags with full names", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, true} = Bandera.enable(:beta)
    {:ok, _live, html} = live(conn, "/flags?view=table")
    assert html =~ "billing_invoices"
    assert html =~ "beta"
  end

  test "table view shows 📅 for flags with schedules", %{conn: conn} do
    {:ok, true} =
      Bandera.enable(:billing_invoices,
        schedule: {"2026-01-01T00:00:00Z", "2027-01-01T00:00:00Z"}
      )

    {:ok, _live, html} = live(conn, "/flags?view=table")
    assert html =~ "📅"
  end

  test "table view shows prerequisite count", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, true} = Bandera.enable(:billing_parent)
    Bandera.enable(:billing_invoices, requires: {:billing_parent, true})

    {:ok, _live, html} = live(conn, "/flags?view=table")
    assert html =~ ">1<"
  end

  test "table row expand shows the gate editor", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, live, _html} = live(conn, "/flags?view=table")
    refute render(live) =~ "add actor"

    html = render_click(live, "toggle_row", %{"flag" => "billing_invoices"})
    assert html =~ "add actor"
  end

  test "table view sorts by name ascending by default", %{conn: conn} do
    {:ok, true} = Bandera.enable(:billing_invoices)
    {:ok, true} = Bandera.enable(:alpha_flag)
    {:ok, _live, html} = live(conn, "/flags?view=table")
    {alpha_pos, _} = :binary.match(html, "alpha_flag")
    {billing_pos, _} = :binary.match(html, "billing_invoices")
    assert alpha_pos < billing_pos
  end

  describe "create flag" do
    test "create form is rendered above the flag list", %{conn: conn} do
      {:ok, _live, html} = live(conn, "/flags")
      assert html =~ ~s(phx-submit="create_flag")
      assert html =~ "new.flag.name"
    end

    test "valid name creates a disabled flag and shows it in the list", %{conn: conn} do
      {:ok, live, _html} = live(conn, "/flags")
      html = render_submit(live, "create_flag", %{"flag_name" => "my_new_flag"})
      assert html =~ "my_new_flag"
      refute Bandera.enabled?(:my_new_flag)
      {:ok, flag} = Bandera.get_flag(:my_new_flag)
      assert Enum.any?(flag.gates, fn g -> g.type == :boolean and not g.enabled end)
    end

    test "blank name shows inline error", %{conn: conn} do
      {:ok, live, _html} = live(conn, "/flags")
      html = render_submit(live, "create_flag", %{"flag_name" => ""})
      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    end

    test "invalid characters show inline error", %{conn: conn} do
      {:ok, live, _html} = live(conn, "/flags")
      html = render_submit(live, "create_flag", %{"flag_name" => "My-Flag!"})
      assert html =~ "lowercase"
    end

    test "name starting with a digit shows inline error", %{conn: conn} do
      {:ok, live, _html} = live(conn, "/flags")
      html = render_submit(live, "create_flag", %{"flag_name" => "1bad"})
      assert html =~ "lowercase"
    end

    test "valid names with dots and underscores are accepted", %{conn: conn} do
      {:ok, live, _html} = live(conn, "/flags")
      html = render_submit(live, "create_flag", %{"flag_name" => "billing.invoices_v2"})
      assert html =~ "billing.invoices_v2"
    end

    test "name exceeding 64 characters shows inline error", %{conn: conn} do
      {:ok, live, _html} = live(conn, "/flags")
      long_name = String.duplicate("a", 65)
      html = render_submit(live, "create_flag", %{"flag_name" => long_name})
      assert html =~ "64 characters"
    end
  end

  describe "similarity warnings" do
    test "no warning shown when flag names are distinct", %{conn: conn} do
      {:ok, false} = Bandera.disable(:billing_invoices)
      {:ok, false} = Bandera.disable(:checkout)
      {:ok, _live, html} = live(conn, "/flags")
      refute html =~ "Possible typos detected"
    end

    test "shows similarity warning when two flags are near-duplicates", %{conn: conn} do
      {:ok, false} = Bandera.disable(:checkout)
      {:ok, false} = Bandera.disable(:chekout)
      {:ok, _live, html} = live(conn, "/flags")
      assert html =~ "Possible typos detected"
      assert html =~ "checkout"
      assert html =~ "chekout"
    end

    test "similarity warning appears above the flag list", %{conn: conn} do
      {:ok, false} = Bandera.disable(:checkout)
      {:ok, false} = Bandera.disable(:chekout)
      {:ok, _live, html} = live(conn, "/flags")
      {warning_pos, _} = :binary.match(html, "Possible typos detected")

      # match the class attribute in the rendered HTML, not the CSS definition in the <style> block
      {flag_pos, _} = :binary.match(html, ~s(class="bandera-row"))
      assert warning_pos < flag_pos
    end

    test "warning disappears after similar flag is cleared", %{conn: conn} do
      {:ok, false} = Bandera.disable(:checkout)
      {:ok, false} = Bandera.disable(:chekout)
      {:ok, live, html} = live(conn, "/flags")
      assert html =~ "Possible typos detected"
      html = render_click(live, "clear_flag", %{"flag" => "chekout"})
      refute html =~ "Possible typos detected"
    end
  end

  test "refreshes when another node broadcasts a flag change", %{conn: conn} do
    Application.put_env(:bandera, :cache_bust_notifications,
      enabled: true,
      adapter: Bandera.Notifications.PhoenixPubSub,
      client: Bandera.Dashboard.TestPubSub
    )

    Bandera.reload_config()

    on_exit(fn ->
      Application.delete_env(:bandera, :cache_bust_notifications)
      Bandera.reload_config()
    end)

    {:ok, live, html} = live(conn, "/flags")
    refute html =~ "promo_banner"

    {:ok, true} = Bandera.enable(:promo_banner)

    Phoenix.PubSub.broadcast(
      Bandera.Dashboard.TestPubSub,
      "bandera:changes",
      {:bandera_change, :promo_banner, "other-node"}
    )

    assert render(live) =~ "promo_banner"
  end

  describe "named instance dashboard" do
    @named Bandera.Dashboard.TestInstance

    setup do
      start_supervised!(
        {Bandera,
         name: @named,
         persistence: [adapter: Bandera.Store.Persistent.Memory],
         dashboard: [group_separator: "_"]}
      )

      :ok
    end

    test "lists only that instance's flags", %{conn: conn} do
      {:ok, true} = Bandera.enable(:default_only)
      {:ok, true} = Bandera.enable(:named_only, instance: @named)

      {:ok, _live, html} = live(conn, "/other-flags")

      assert html =~ "named_only"
      refute html =~ "default_only"
    end

    test "toggling from it writes to the named instance, not the default", %{conn: conn} do
      {:ok, false} = Bandera.disable(:shared_name)
      {:ok, false} = Bandera.disable(:shared_name, instance: @named)

      {:ok, live, _html} = live(conn, "/other-flags")
      render_click(live, "toggle_boolean", %{"flag" => "shared_name"})

      assert Bandera.enabled?(:shared_name, instance: @named)
      refute Bandera.enabled?(:shared_name)
    end

    test "a broadcast on the default instance's topic does not refresh it", %{conn: conn} do
      {:ok, live, html} = live(conn, "/other-flags")
      refute html =~ "promo_banner"

      {:ok, true} = Bandera.enable(:promo_banner, instance: @named)

      # This dashboard is bound to @named, which has no PubSub notifications
      # configured, so it never subscribed to any topic at all.
      Phoenix.PubSub.broadcast(
        Bandera.Dashboard.TestPubSub,
        "bandera:changes",
        {:bandera_change, :promo_banner, "other-node"}
      )

      refute render(live) =~ "promo_banner"
    end
  end

  describe "named instance dashboard with cache-busting notifications" do
    @named Bandera.Dashboard.TestInstance

    setup do
      # Starts the instance's real PhoenixPubSub notifier alongside the dashboard.
      start_supervised!(
        {Bandera,
         name: @named,
         persistence: [adapter: Bandera.Store.Persistent.Memory],
         dashboard: [group_separator: "_"],
         cache_bust_notifications: [
           enabled: true,
           adapter: Bandera.Notifications.PhoenixPubSub,
           client: Bandera.Dashboard.TestPubSub
         ]}
      )

      :ok
    end

    test "refreshes when another node broadcasts on the instance's own topic", %{conn: conn} do
      conf = Bandera.Config.get(@named)

      assert Bandera.Notifications.topic(conf) ==
               "bandera:{Bandera.Dashboard.TestInstance}:changes"

      {:ok, live, html} = live(conn, "/other-flags")
      refute html =~ "promo_banner"

      {:ok, true} = Bandera.enable(:promo_banner, instance: @named)

      Phoenix.PubSub.broadcast(
        Bandera.Dashboard.TestPubSub,
        Bandera.Notifications.topic(conf),
        {:bandera_change, :promo_banner, "other-node"}
      )

      assert render(live) =~ "promo_banner"
    end
  end

  defp actor_gate(flag_name, target), do: find_gate(flag_name, :actor, target)
  defp group_gate(flag_name, target), do: find_gate(flag_name, :group, target)

  defp find_gate(flag_name, type, target) do
    {:ok, flag} = Bandera.get_flag(flag_name)

    Enum.find(flag.gates, fn g ->
      g.type == type and to_string(g.for) == to_string(target)
    end)
  end

  defp eventually(fun, timeout \\ 2_000, interval \\ 10) do
    cond do
      fun.() ->
        true

      timeout <= 0 ->
        false

      true ->
        Process.sleep(interval)
        eventually(fun, timeout - interval, interval)
    end
  end
end
