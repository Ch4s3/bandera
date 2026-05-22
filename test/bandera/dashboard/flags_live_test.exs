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
end
