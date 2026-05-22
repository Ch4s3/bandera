if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Bandera.Dashboard.FlagsLive do
    @moduledoc "The Bandera flag dashboard LiveView."
    use Phoenix.LiveView

    import Bandera.Dashboard.Components

    @impl true
    def mount(_params, _session, socket) do
      socket =
        socket
        |> assign(search: "", expanded: MapSet.new(), flash_error: nil)
        |> load_flags()

      {:ok, socket}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.styles />
      <div class="bandera-wrap">
        <h1>Bandera</h1>

        <div :if={@flash_error} class="bandera-flash">{@flash_error}</div>

        <form phx-change="search" phx-submit="search">
          <input
            class="bandera-search"
            type="text"
            name="q"
            value={@search}
            placeholder="Search flags…"
            autocomplete="off"
            phx-debounce="150"
          />
        </form>

        <details :for={{group, members} <- @groups} class="bandera-group" open>
          <summary>{group} <span class="bandera-count">({length(members)})</span></summary>

          <div :for={{display, flag} <- members}>
            <div class="bandera-row">
              <span>
                <span class="bandera-name">{display}</span>
                <.state_summary flag={flag} />
              </span>
              <span>
                <button
                  type="button"
                  class={["bandera-toggle", !boolean_on?(flag) && "bandera-off"]}
                  phx-click="toggle_boolean"
                  phx-value-flag={flag.name}
                >
                  {if boolean_on?(flag), do: "on", else: "off"}
                </button>
                <button type="button" phx-click="toggle_row" phx-value-flag={flag.name}>
                  {if expanded?(@expanded, flag), do: "▴", else: "▾"}
                </button>
              </span>
            </div>

            <div :if={expanded?(@expanded, flag)} class="bandera-editor">
              {render_editor(assigns, flag)}
            </div>
          </div>
        </details>
      </div>
      """
    end

    # ---- editor (inline; extract into Components later if it grows) ----

    defp render_editor(assigns, flag) do
      assigns = Phoenix.Component.assign(assigns, :flag, flag)

      ~H"""
      <fieldset>
        <legend>Actors</legend>
        <ul class="bandera-gate-list">
          <li :for={id <- actor_targets(@flag)}>
            <code>{id}</code>
            <button
              type="button"
              class="bandera-danger"
              phx-click="remove_actor"
              phx-value-flag={@flag.name}
              phx-value-actor={id}
            >remove</button>
          </li>
        </ul>
        <form phx-submit="add_actor">
          <input type="hidden" name="flag" value={@flag.name} />
          <input type="text" name="actor" placeholder="actor id" />
          <button class="bandera-primary">add actor</button>
        </form>
      </fieldset>

      <fieldset>
        <legend>Groups</legend>
        <ul class="bandera-gate-list">
          <li :for={name <- group_targets(@flag)}>
            <code>{name}</code>
            <button
              type="button"
              class="bandera-danger"
              phx-click="remove_group"
              phx-value-flag={@flag.name}
              phx-value-group={name}
            >remove</button>
          </li>
        </ul>
        <form phx-submit="add_group">
          <input type="hidden" name="flag" value={@flag.name} />
          <input type="text" name="group" placeholder="group name" />
          <button class="bandera-primary">add group</button>
        </form>
      </fieldset>

      <fieldset>
        <legend>Percentage</legend>
        <form phx-submit="set_percentage">
          <input type="hidden" name="flag" value={@flag.name} />
          <input type="number" name="percent" min="1" max="99" placeholder="%" />
          <select name="kind">
            <option value="actors">of actors</option>
            <option value="time">of time</option>
          </select>
          <button class="bandera-primary">set</button>
          <button type="button" phx-click="clear_percentage" phx-value-flag={@flag.name}>
            clear
          </button>
        </form>
      </fieldset>

      <button
        type="button"
        class="bandera-danger"
        phx-click="clear_flag"
        phx-value-flag={@flag.name}
      >
        Clear whole flag
      </button>
      """
    end

    # ---- assigns helpers ----

    defp load_flags(socket) do
      flags =
        case Bandera.all_flags() do
          {:ok, flags} -> flags
          {:error, _} -> []
        end

      socket |> assign(:all_flags, flags) |> recompute_groups()
    end

    defp recompute_groups(socket) do
      separator = Bandera.Config.group_separator()

      filtered =
        for flag <- socket.assigns.all_flags,
            matches?(flag, socket.assigns.search),
            do: flag

      assign(socket, :groups, Bandera.Dashboard.Grouping.group(filtered, separator))
    end

    defp matches?(_flag, ""), do: true

    defp matches?(flag, search) do
      String.contains?(String.downcase(to_string(flag.name)), String.downcase(search))
    end

    defp boolean_on?(flag) do
      Enum.any?(flag.gates, fn g -> Bandera.Gate.boolean?(g) and g.enabled end)
    end

    defp expanded?(expanded, flag), do: MapSet.member?(expanded, to_string(flag.name))

    defp actor_targets(flag) do
      for g <- flag.gates, Bandera.Gate.actor?(g), do: g.for
    end

    defp group_targets(flag) do
      for g <- flag.gates, Bandera.Gate.group?(g), do: g.for
    end
  end
end
