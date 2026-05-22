defmodule Bandera.Dashboard.ThemeTest do
  use ExUnit.Case, async: true

  alias Bandera.Dashboard.Theme

  test "standalone maps roles to bandera-prefixed classes" do
    assert Theme.class(:standalone, :wrap) == "bandera-wrap"
    assert Theme.class(:standalone, :group) == "bandera-group"
    assert Theme.class(:standalone, :row) == "bandera-row"
    assert Theme.class(:standalone, :primary_button) == "bandera-primary"
    assert Theme.class(:standalone, :toggle_on) == "bandera-toggle"
    assert Theme.class(:standalone, :toggle_off) == "bandera-toggle bandera-off"
    assert Theme.class(:standalone, :summary) == "bandera-summary"
  end

  test "daisyui maps roles to daisyUI/Tailwind classes" do
    assert Theme.class(:daisyui, :primary_button) == "btn btn-primary btn-sm"
    assert Theme.class(:daisyui, :toggle_on) =~ "btn-success"
    assert Theme.class(:daisyui, :flash) =~ "alert-error"
    assert Theme.class(:daisyui, :search) =~ "input"
    refute Theme.class(:daisyui, :row) =~ "bandera-"
  end

  test "an unknown theme falls back to standalone classes" do
    assert Theme.class(:neon, :wrap) == "bandera-wrap"
  end

  test "every role resolves to a non-empty class in both themes" do
    for role <- Theme.roles(), theme <- [:standalone, :daisyui] do
      class = Theme.class(theme, role)
      assert is_binary(class) and class != "", "#{theme}/#{role} resolved to an empty class"
    end
  end
end
