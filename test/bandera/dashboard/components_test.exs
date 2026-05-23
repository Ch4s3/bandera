defmodule Bandera.Dashboard.ComponentsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias Bandera.Constraint
  alias Bandera.Dashboard.Components
  alias Bandera.Flag
  alias Bandera.Gate

  defp summary(gates) do
    render_component(&Components.state_summary/1, flag: Flag.new(:f, gates))
  end

  test "no gates" do
    assert summary([]) =~ "no gates"
    assert summary([]) =~ ~s(class="bandera-summary")
  end

  test "boolean on/off" do
    assert summary([Gate.new(:boolean, true)]) =~ "on"
    assert summary([Gate.new(:boolean, false)]) =~ "off"
  end

  test "percentage of actors and of time" do
    assert summary([Gate.new(:percentage_of_actors, 0.25)]) =~ "25% of actors"
    assert summary([Gate.new(:percentage_of_time, 0.1)]) =~ "10% of time"
  end

  test "counts actor and group gates" do
    out =
      summary([
        Gate.new(:actor, "u1", true),
        Gate.new(:actor, "u2", true),
        Gate.new(:group, "beta", true)
      ])

    assert out =~ "2 actors"
    assert out =~ "1 group"
  end

  test "combines parts with a separator" do
    out = summary([Gate.new(:boolean, false), Gate.new(:actor, "u1", true)])
    assert out =~ "off"
    assert out =~ "1 actor"
    assert out =~ "·"
  end

  test "variant weights" do
    out = summary([Gate.new(:variant, %{"blue" => 1, "green" => 1})])
    assert out =~ "variants blue 50%, green 50%"
  end

  test "rule constraint count" do
    c = Constraint.new("plan", :eq, "pro")
    assert summary([Gate.new(:rule, [c], true)]) =~ "rule (1 constraint)"
    assert summary([Gate.new(:rule, [c, c], true)]) =~ "rule (2 constraints)"
  end

  test "counts segment and prerequisite gates" do
    out =
      summary([
        Gate.new(:segment, "premium", true),
        Gate.new(:segment, "beta", true),
        Gate.new(:prerequisite, :billing, true)
      ])

    assert out =~ "2 segments"
    assert out =~ "1 prerequisite"
  end

  test "schedule window, open-ended on either side" do
    assert summary([Gate.new(:schedule, {"2026-01-01T00:00:00Z", "2026-06-01T00:00:00Z"})]) =~
             "scheduled 2026-01-01T00:00:00Z → 2026-06-01T00:00:00Z"

    assert summary([Gate.new(:schedule, {"2026-01-01T00:00:00Z", nil})]) =~
             "scheduled from 2026-01-01T00:00:00Z"

    assert summary([Gate.new(:schedule, {nil, "2026-06-01T00:00:00Z"})]) =~
             "scheduled until 2026-06-01T00:00:00Z"

    assert summary([Gate.new(:schedule, {nil, nil})]) =~ "scheduled"
  end

  test "combines a new gate part with the separator" do
    out = summary([Gate.new(:boolean, false), Gate.new(:segment, "premium", true)])
    assert out =~ "off"
    assert out =~ "1 segment"
    assert out =~ "·"
  end

  test "styles/1 renders a style block with prefixed selectors" do
    html = render_component(&Components.styles/1, [])
    assert html =~ "<style"
    assert html =~ ".bandera-wrap"
    assert html =~ ".bandera-toggle"
  end
end
