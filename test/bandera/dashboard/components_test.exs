defmodule Bandera.Dashboard.ComponentsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

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

  test "styles/1 renders a style block with prefixed selectors" do
    html = render_component(&Components.styles/1, [])
    assert html =~ "<style"
    assert html =~ ".bandera-wrap"
    assert html =~ ".bandera-toggle"
  end
end
