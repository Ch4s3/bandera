if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Bandera.Dashboard.FlagsLive do
    @moduledoc "The Bandera flag dashboard LiveView."
    use Phoenix.LiveView

    import Bandera.Dashboard.Components
    alias Bandera.Dashboard.Theme

    @constraint_operators ~w(eq neq in not_in contains gt gte lt lte matches)a

    @impl true
    def mount(_params, _session, socket) do
      if connected?(socket), do: subscribe_to_changes()

      socket =
        socket
        |> assign(
          search: "",
          expanded: MapSet.new(),
          collapsed_groups: MapSet.new(),
          actor_drafts: %{},
          group_drafts: %{},
          theme: Bandera.Config.theme(),
          flash_error: nil
        )
        |> load_flags()

      {:ok, socket}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.styles theme={@theme} />
      <div class={Theme.class(@theme, :wrap)}>
        <h1 class={Theme.class(@theme, :heading)}>Bandera</h1>

        <div :if={@flash_error} class={Theme.class(@theme, :flash)}>{@flash_error}</div>

        <form phx-change="search" phx-submit="search">
          <input
            class={Theme.class(@theme, :search)}
            type="text"
            name="q"
            value={@search}
            placeholder="Search flags…"
            autocomplete="off"
            phx-debounce="150"
          />
        </form>

        <details
          :for={{group, members} <- @groups}
          class={Theme.class(@theme, :group)}
          open={not group_collapsed?(@collapsed_groups, group)}
        >
          <summary
            class={Theme.class(@theme, :group_summary)}
            phx-click="toggle_group"
            phx-value-group={group}
          >
            {group} <span class={Theme.class(@theme, :count)}>({length(members)})</span>
          </summary>

          <div :for={{display, flag} <- members}>
            <div class={Theme.class(@theme, :row)}>
              <span>
                <span class={Theme.class(@theme, :name)}>{display}</span>
                <.state_summary flag={flag} theme={@theme} />
              </span>
              <span>
                <button
                  type="button"
                  class={Theme.class(@theme, toggle_role(flag))}
                  phx-click="toggle_boolean"
                  phx-value-flag={flag.name}
                >{if boolean_on?(flag), do: "on", else: "off"}</button>
                <button
                  type="button"
                  class={Theme.class(@theme, :icon_button)}
                  phx-click="toggle_row"
                  phx-value-flag={flag.name}
                >
                  {if expanded?(@expanded, flag), do: "▴", else: "▾"}
                </button>
              </span>
            </div>

            <div :if={expanded?(@expanded, flag)} class={Theme.class(@theme, :editor)}>
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

    def handle_event("toggle_group", %{"group" => group}, socket) do
      collapsed = socket.assigns.collapsed_groups

      collapsed =
        if MapSet.member?(collapsed, group),
          do: MapSet.delete(collapsed, group),
          else: MapSet.put(collapsed, group)

      {:noreply, assign(socket, :collapsed_groups, collapsed)}
    end

    def handle_event("toggle_boolean", %{"flag" => name}, socket) do
      flag_name = String.to_existing_atom(name)

      if currently_on?(socket, name),
        do: Bandera.disable(flag_name),
        else: Bandera.enable(flag_name)

      {:noreply, socket |> assign(:flash_error, nil) |> refresh()}
    end

    def handle_event("actor_input", %{"flag" => name, "actor" => actor}, socket) do
      {:noreply, update(socket, :actor_drafts, &Map.put(&1, name, actor))}
    end

    def handle_event("add_actor", %{"flag" => name, "actor" => actor}, socket) do
      actor = String.trim(actor)

      if actor == "" do
        {:noreply, assign(socket, :flash_error, "Actor id can't be blank.")}
      else
        Bandera.enable(String.to_existing_atom(name), for_actor: actor)

        {:noreply,
         socket
         |> assign(:flash_error, nil)
         |> update(:actor_drafts, &Map.delete(&1, name))
         |> refresh()}
      end
    end

    def handle_event("remove_actor", %{"flag" => name, "actor" => actor}, socket) do
      Bandera.clear(String.to_existing_atom(name), for_actor: actor)
      {:noreply, refresh(socket)}
    end

    def handle_event("group_input", %{"flag" => name, "group" => group}, socket) do
      {:noreply, update(socket, :group_drafts, &Map.put(&1, name, group))}
    end

    def handle_event("add_group", %{"flag" => name, "group" => group}, socket) do
      group = String.trim(group)

      if group == "" do
        {:noreply, assign(socket, :flash_error, "Group name can't be blank.")}
      else
        Bandera.enable(String.to_existing_atom(name), for_group: group)

        {:noreply,
         socket
         |> assign(:flash_error, nil)
         |> update(:group_drafts, &Map.delete(&1, name))
         |> refresh()}
      end
    end

    def handle_event("remove_group", %{"flag" => name, "group" => group}, socket) do
      Bandera.clear(String.to_existing_atom(name), for_group: group)
      {:noreply, refresh(socket)}
    end

    def handle_event(
          "set_percentage",
          %{"flag" => name, "percent" => percent, "kind" => kind},
          socket
        ) do
      with {pct, ""} <- Integer.parse(String.trim(percent)),
           true <- pct >= 1 and pct <= 99,
           {:ok, gate_kind} <- percentage_kind(kind) do
        Bandera.enable(String.to_existing_atom(name), for_percentage_of: {gate_kind, pct / 100})
        {:noreply, socket |> assign(:flash_error, nil) |> refresh()}
      else
        _ ->
          {:noreply,
           assign(socket, :flash_error, "Percentage must be a whole number between 1 and 99.")}
      end
    end

    def handle_event("clear_percentage", %{"flag" => name}, socket) do
      Bandera.clear(String.to_existing_atom(name), for_percentage: true)
      {:noreply, refresh(socket)}
    end

    def handle_event(
          "add_variant",
          %{"flag" => name, "variant" => variant, "weight" => weight},
          socket
        ) do
      with variant when variant != "" <- String.trim(variant),
           {:ok, w} when w > 0 <- parse_number(String.trim(weight)) do
        weights = name |> current_weights(socket) |> Map.put(variant, w)
        Bandera.put_variants(String.to_existing_atom(name), weights)
        {:noreply, socket |> assign(:flash_error, nil) |> refresh()}
      else
        _ ->
          {:noreply, assign(socket, :flash_error, "Variant needs a name and a positive weight.")}
      end
    end

    def handle_event("remove_variant", %{"flag" => name, "variant" => variant}, socket) do
      flag_name = String.to_existing_atom(name)
      weights = name |> current_weights(socket) |> Map.delete(variant)

      if map_size(weights) == 0,
        do: Bandera.clear(flag_name, variant: true),
        else: Bandera.put_variants(flag_name, weights)

      {:noreply, socket |> assign(:flash_error, nil) |> refresh()}
    end

    def handle_event(
          "add_constraint",
          %{"flag" => name, "attribute" => attr, "operator" => op, "values" => values},
          socket
        ) do
      with attr when attr != "" <- String.trim(attr),
           {:ok, operator} <- parse_operator(op) do
        constraint = Bandera.Constraint.new(attr, operator, parse_values(values))
        constraints = current_constraints(name, socket) ++ [constraint]
        Bandera.enable(String.to_existing_atom(name), when: constraints)
        {:noreply, socket |> assign(:flash_error, nil) |> refresh()}
      else
        _ ->
          {:noreply,
           assign(socket, :flash_error, "Rule needs an attribute and a valid operator.")}
      end
    end

    def handle_event("remove_constraint", %{"flag" => name, "index" => index}, socket) do
      case Integer.parse(index) do
        {i, ""} ->
          flag_name = String.to_existing_atom(name)
          constraints = current_constraints(name, socket) |> List.delete_at(i)

          if constraints == [],
            do: Bandera.clear(flag_name, rule: true),
            else: Bandera.enable(flag_name, when: constraints)

          {:noreply, socket |> assign(:flash_error, nil) |> refresh()}

        _ ->
          {:noreply, socket}
      end
    end

    def handle_event("clear_flag", %{"flag" => name}, socket) do
      flag_name = String.to_existing_atom(name)
      Bandera.clear(flag_name)

      {:noreply,
       socket
       |> update(:expanded, &MapSet.delete(&1, name))
       |> refresh()}
    end

    @impl true
    def handle_info({:bandera_change, _flag, _id}, socket) do
      {:noreply, refresh(socket)}
    end

    def handle_info(_msg, socket), do: {:noreply, socket}

    # ---- editor (inline; extract into Components later if it grows) ----

    defp render_editor(assigns, flag) do
      assigns = Phoenix.Component.assign(assigns, :flag, flag)

      ~H"""
      <fieldset class={Theme.class(@theme, :fieldset)}>
        <legend class={Theme.class(@theme, :legend)}>Actors</legend>
        <ul class={Theme.class(@theme, :gate_list)}>
          <li :for={id <- actor_targets(@flag)} class={Theme.class(@theme, :gate_item)}>
            <code>{id}</code>
            <button
              type="button"
              class={Theme.class(@theme, :danger_button)}
              phx-click="remove_actor"
              phx-value-flag={@flag.name}
              phx-value-actor={id}
            >remove</button>
          </li>
        </ul>
        <form phx-submit="add_actor" phx-change="actor_input">
          <input type="hidden" name="flag" value={@flag.name} />
          <input
            type="text"
            name="actor"
            value={Map.get(@actor_drafts, to_string(@flag.name), "")}
            placeholder="actor id"
            class={Theme.class(@theme, :input)}
          />
          <button class={Theme.class(@theme, :primary_button)}>add actor</button>
        </form>
      </fieldset>

      <fieldset class={Theme.class(@theme, :fieldset)}>
        <legend class={Theme.class(@theme, :legend)}>Groups</legend>
        <ul class={Theme.class(@theme, :gate_list)}>
          <li :for={name <- group_targets(@flag)} class={Theme.class(@theme, :gate_item)}>
            <code>{name}</code>
            <button
              type="button"
              class={Theme.class(@theme, :danger_button)}
              phx-click="remove_group"
              phx-value-flag={@flag.name}
              phx-value-group={name}
            >remove</button>
          </li>
        </ul>
        <form phx-submit="add_group" phx-change="group_input">
          <input type="hidden" name="flag" value={@flag.name} />
          <input
            type="text"
            name="group"
            value={Map.get(@group_drafts, to_string(@flag.name), "")}
            placeholder="group name"
            class={Theme.class(@theme, :input)}
          />
          <button class={Theme.class(@theme, :primary_button)}>add group</button>
        </form>
      </fieldset>

      <fieldset class={Theme.class(@theme, :fieldset)}>
        <legend class={Theme.class(@theme, :legend)}>Percentage</legend>
        <form phx-submit="set_percentage">
          <input type="hidden" name="flag" value={@flag.name} />
          <input
            type="number"
            name="percent"
            min="1"
            max="99"
            placeholder="%"
            class={Theme.class(@theme, :input)}
          />
          <select name="kind" class={Theme.class(@theme, :select)}>
            <option value="actors">of actors</option>
            <option value="time">of time</option>
          </select>
          <button class={Theme.class(@theme, :primary_button)}>set</button>
          <button
            type="button"
            class={Theme.class(@theme, :neutral_button)}
            phx-click="clear_percentage"
            phx-value-flag={@flag.name}
          >
            clear
          </button>
        </form>
      </fieldset>

      {render_variants(assigns, @flag)}
      {render_rule(assigns, @flag)}

      <button
        type="button"
        class={Theme.class(@theme, :danger_button)}
        phx-click="clear_flag"
        phx-value-flag={@flag.name}
      >
        Clear whole flag
      </button>
      """
    end

    defp render_variants(assigns, flag) do
      assigns = Phoenix.Component.assign(assigns, :flag, flag)

      ~H"""
      <fieldset class={Theme.class(@theme, :fieldset)}>
        <legend class={Theme.class(@theme, :legend)}>Variants</legend>
        <ul class={Theme.class(@theme, :gate_list)}>
          <li :for={{name, weight} <- variant_weights(@flag)} class={Theme.class(@theme, :gate_item)}>
            <code>{name} ({weight})</code>
            <button
              type="button"
              class={Theme.class(@theme, :danger_button)}
              phx-click="remove_variant"
              phx-value-flag={@flag.name}
              phx-value-variant={name}
            >remove</button>
          </li>
        </ul>
        <form phx-submit="add_variant">
          <input type="hidden" name="flag" value={@flag.name} />
          <input type="text" name="variant" placeholder="variant name" class={Theme.class(@theme, :input)} />
          <input type="number" name="weight" min="1" step="any" placeholder="weight" class={Theme.class(@theme, :input)} />
          <button class={Theme.class(@theme, :primary_button)}>add variant</button>
        </form>
      </fieldset>
      """
    end

    defp render_rule(assigns, flag) do
      assigns =
        assigns
        |> Phoenix.Component.assign(:flag, flag)
        |> Phoenix.Component.assign(:constraints, rule_constraints(flag))
        |> Phoenix.Component.assign(:operators, @constraint_operators)

      ~H"""
      <fieldset class={Theme.class(@theme, :fieldset)}>
        <legend class={Theme.class(@theme, :legend)}>Rule</legend>
        <ul class={Theme.class(@theme, :gate_list)}>
          <li :for={{c, i} <- Enum.with_index(@constraints)} class={Theme.class(@theme, :gate_item)}>
            <code>{c.attribute} {c.operator} {Enum.join(c.values, ", ")}</code>
            <button
              type="button"
              class={Theme.class(@theme, :danger_button)}
              phx-click="remove_constraint"
              phx-value-flag={@flag.name}
              phx-value-index={i}
            >remove</button>
          </li>
        </ul>
        <form phx-submit="add_constraint">
          <input type="hidden" name="flag" value={@flag.name} />
          <input type="text" name="attribute" placeholder="attribute" class={Theme.class(@theme, :input)} />
          <select name="operator" class={Theme.class(@theme, :select)}>
            <option :for={op <- @operators} value={op}>{op}</option>
          </select>
          <input type="text" name="values" placeholder="values (comma-separated)" class={Theme.class(@theme, :input)} />
          <button class={Theme.class(@theme, :primary_button)}>add constraint</button>
        </form>
      </fieldset>
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

    defp group_collapsed?(collapsed, group), do: MapSet.member?(collapsed, group)

    defp toggle_role(flag), do: if(boolean_on?(flag), do: :toggle_on, else: :toggle_off)

    defp actor_targets(flag) do
      for g <- flag.gates, Bandera.Gate.actor?(g), do: g.for
    end

    defp group_targets(flag) do
      for g <- flag.gates, Bandera.Gate.group?(g), do: g.for
    end

    defp current_flag(socket, name),
      do: Enum.find(socket.assigns.all_flags, &(to_string(&1.name) == name))

    defp variant_weights(flag) do
      case Enum.find(flag.gates, &Bandera.Gate.variant?/1) do
        nil -> %{}
        gate -> gate.value
      end
    end

    defp current_weights(name, socket) do
      case current_flag(socket, name) do
        nil -> %{}
        flag -> variant_weights(flag)
      end
    end

    defp rule_constraints(flag) do
      case Enum.find(flag.gates, &Bandera.Gate.rule?/1) do
        nil -> []
        gate -> gate.value
      end
    end

    defp current_constraints(name, socket) do
      case current_flag(socket, name) do
        nil -> []
        flag -> rule_constraints(flag)
      end
    end

    defp coerce_value(token) do
      case parse_number(token) do
        {:ok, n} -> n
        :error -> token
      end
    end

    defp parse_values(str) do
      str
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&coerce_value/1)
    end

    defp parse_operator(op) do
      case Enum.find(@constraint_operators, &(Atom.to_string(&1) == op)) do
        nil -> :error
        atom -> {:ok, atom}
      end
    end

    defp parse_number(str) do
      case Integer.parse(str) do
        {i, ""} ->
          {:ok, i}

        _ ->
          case Float.parse(str) do
            {f, ""} -> {:ok, f}
            _ -> :error
          end
      end
    end

    defp currently_on?(socket, name) do
      Enum.any?(socket.assigns.all_flags, fn flag ->
        to_string(flag.name) == name and boolean_on?(flag)
      end)
    end

    defp refresh(socket), do: load_flags(socket)

    @change_topic "bandera:changes"

    defp subscribe_to_changes do
      with true <- Bandera.Config.notifications_adapter() == Bandera.Notifications.PhoenixPubSub,
           client when not is_nil(client) <- Keyword.get(Bandera.Config.notifications(), :client) do
        Phoenix.PubSub.subscribe(client, @change_topic)
      else
        _ -> :ok
      end
    end

    defp percentage_kind("actors"), do: {:ok, :actors}
    defp percentage_kind("time"), do: {:ok, :time}
    defp percentage_kind(_), do: :error
  end
end
