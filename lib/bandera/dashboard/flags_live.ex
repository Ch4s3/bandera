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
                >{if boolean_on?(flag), do: "on", else: "off"}</button>
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

    @impl true
    def handle_event("search", %{"q" => q}, socket) do
      {:noreply, socket |> assign(search: q) |> recompute_groups()}
    end

    def handle_event("toggle_row", %{"flag" => name}, socket) do
      expanded = socket.assigns.expanded

      expanded =
        if MapSet.member?(expanded, name),
          do: MapSet.delete(expanded, name),
          else: MapSet.put(expanded, name)

      {:noreply, socket |> assign(:flash_error, nil) |> assign(:expanded, expanded)}
    end

    def handle_event("toggle_boolean", %{"flag" => name}, socket) do
      flag_name = String.to_existing_atom(name)

      if currently_on?(socket, name),
        do: Bandera.disable(flag_name),
        else: Bandera.enable(flag_name)

      {:noreply, socket |> assign(:flash_error, nil) |> refresh()}
    end

    def handle_event("add_actor", %{"flag" => name, "actor" => actor}, socket) do
      actor = String.trim(actor)

      if actor == "" do
        {:noreply, assign(socket, :flash_error, "Actor id can't be blank.")}
      else
        Bandera.enable(String.to_existing_atom(name), for_actor: actor)
        {:noreply, socket |> assign(:flash_error, nil) |> refresh()}
      end
    end

    def handle_event("remove_actor", %{"flag" => name, "actor" => actor}, socket) do
      Bandera.clear(String.to_existing_atom(name), for_actor: actor)
      {:noreply, refresh(socket)}
    end

    def handle_event("add_group", %{"flag" => name, "group" => group}, socket) do
      group = String.trim(group)

      if group == "" do
        {:noreply, assign(socket, :flash_error, "Group name can't be blank.")}
      else
        Bandera.enable(String.to_existing_atom(name), for_group: group)
        {:noreply, socket |> assign(:flash_error, nil) |> refresh()}
      end
    end

    def handle_event("remove_group", %{"flag" => name, "group" => group}, socket) do
      Bandera.clear(String.to_existing_atom(name), for_group: group)
      {:noreply, refresh(socket)}
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

    defp currently_on?(socket, name) do
      Enum.any?(socket.assigns.all_flags, fn flag ->
        to_string(flag.name) == name and boolean_on?(flag)
      end)
    end

    defp refresh(socket), do: load_flags(socket)
  end
end
