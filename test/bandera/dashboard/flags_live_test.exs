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
end
