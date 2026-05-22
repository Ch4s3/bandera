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
end
