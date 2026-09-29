if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Bandera.Dashboard.FlagsLive do
    @moduledoc "The Bandera flag dashboard LiveView."
    use Phoenix.LiveView

    import Bandera.Dashboard.Components
    alias Bandera.Dashboard.Theme

    @usage_refresh_interval 1_000

    @impl true
    def mount(_params, session, socket) do
      instance = Map.get(session, "bandera_instance", Bandera.Config.default_instance())
      conf = Bandera.Config.get(instance)
      usage_status = Bandera.Dashboard.Stale.usage_status(instance)

      if connected?(socket) do
        subscribe_to_changes(conf)
        if usage_status == :loading, do: schedule_usage_refresh()
      end

      socket =
        socket
        |> assign(
          instance: instance,
          search: "",
          expanded: MapSet.new(),
          collapsed_groups: MapSet.new(),
          actor_drafts: %{},
          group_drafts: %{},
          theme: conf.theme,
          flash_error: nil,
          view: :cards,
          grouped: true,
          sort: :name,
          sort_dir: :asc,
          stale_set: Bandera.Dashboard.Stale.stale_set(instance),
          usage_status: usage_status,
          create_error: nil,
          similar_pairs: [],
          base_path: "/"
        )
        |> load_flags()

      {:ok, socket}
    end

    @impl true
    def handle_params(params, uri, socket) do
      view = if params["view"] == "table", do: :table, else: :cards
      grouped = params["grouped"] != "false"
      sort = parse_sort(params["sort"])
      sort_dir = if params["dir"] == "desc", do: :desc, else: :asc
      base_path = URI.parse(uri).path

      {:noreply,
       socket
       |> assign(
         view: view,
         grouped: grouped,
         sort: sort,
         sort_dir: sort_dir,
         base_path: base_path
       )
       |> recompute_groups()}
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

        <form phx-submit="create_flag" class={Theme.class(@theme, :create_form)}>
          <input
            class={Theme.class(@theme, :input)}
            type="text"
            name="flag_name"
            placeholder="new.flag.name"
            autocomplete="off"
          />
          <button class={Theme.class(@theme, :primary_button)} type="submit">Create</button>
        </form>
        <div :if={@create_error} class={Theme.class(@theme, :flash)}>
          {@create_error}
        </div>

        <.usage_warning
          :if={@usage_status != :ready}
          status={@usage_status}
          theme={@theme}
          instance={@instance}
        />

        <.similarity_warning :if={@similar_pairs != []} pairs={@similar_pairs} theme={@theme} />

        <div class={Theme.class(@theme, :view_controls)}>
          <span>
            <.link
              patch={@base_path <> "?" <> URI.encode_query(%{"view" => "cards", "grouped" => to_string(@grouped)})}
              class={Theme.class(@theme, if(@view == :cards, do: :view_toggle_active, else: :view_toggle_inactive))}
            >Cards</.link>
            <.link
              patch={@base_path <> "?view=table"}
              class={Theme.class(@theme, if(@view == :table, do: :view_toggle_active, else: :view_toggle_inactive))}
            >Table</.link>
          </span>
          <.link
            :if={@view == :cards}
            patch={@base_path <> "?" <> URI.encode_query(%{"view" => "cards", "grouped" => to_string(not @grouped)})}
            class={Theme.class(@theme, :grouping_toggle)}
          >
            {if @grouped, do: "[✓]", else: "[ ]"} Group by namespace
          </.link>
        </div>

        <%!-- Grouped card view --%>
        <details
          :if={@view == :cards and @grouped}
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
                <span class={Theme.class(@theme, :name)}>
                  {display}
                  <span
                    :if={@grouped and display != to_string(flag.name)}
                    class={Theme.class(@theme, :full_name)}
                  >{flag.name}</span>
                </span>
                <.state_summary flag={flag} theme={@theme} />
                <.stale_indicator
                  :if={MapSet.member?(@stale_set, flag.name)}
                  flag_name={flag.name}
                  theme={@theme}
                  instance={@instance}
                />
                <span :if={has_schedule?(flag)} class={Theme.class(@theme, :icon_hint)} title="Has a schedule">📅</span>
                <span :if={has_prerequisites?(flag)} class={Theme.class(@theme, :icon_hint)} title="Has prerequisites">🔗</span>
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
              <.flag_editor
                flag={flag}
                theme={@theme}
                actor_drafts={@actor_drafts}
                group_drafts={@group_drafts}
                all_flags={@all_flags}
              />
            </div>
          </div>
        </details>

        <%!-- Flat (ungrouped) card view --%>
        <div :if={@view == :cards and not @grouped}>
          <div :for={{_group, members} <- @groups}>
            <div :for={{display, flag} <- members}>
              <div class={Theme.class(@theme, :row)}>
                <span>
                  <span class={Theme.class(@theme, :name)}>
                    {display}
                  </span>
                  <.state_summary flag={flag} theme={@theme} />
                  <.stale_indicator
                    :if={MapSet.member?(@stale_set, flag.name)}
                    flag_name={flag.name}
                    theme={@theme}
                    instance={@instance}
                  />
                  <span :if={has_schedule?(flag)} class={Theme.class(@theme, :icon_hint)} title="Has a schedule">📅</span>
                  <span :if={has_prerequisites?(flag)} class={Theme.class(@theme, :icon_hint)} title="Has prerequisites">🔗</span>
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
                <.flag_editor
                  flag={flag}
                  theme={@theme}
                  actor_drafts={@actor_drafts}
                  group_drafts={@group_drafts}
                  all_flags={@all_flags}
                />
              </div>
            </div>
          </div>
        </div>

        <%!-- Table view --%>
        <table :if={@view == :table} class={Theme.class(@theme, :table)}>
          <thead>
            <tr>
              <th
                class={"#{Theme.class(@theme, :th)} bandera-th--sortable"}
                phx-click="sort"
                phx-value-col="name"
              >Flag {sort_arrow(:name, @sort, @sort_dir)}</th>
              <th
                class={"#{Theme.class(@theme, :th)} bandera-th--sortable"}
                phx-click="sort"
                phx-value-col="state"
              >State {sort_arrow(:state, @sort, @sort_dir)}</th>
              <th
                class={"#{Theme.class(@theme, :th)} bandera-th--sortable"}
                phx-click="sort"
                phx-value-col="last_evaluated"
              >Last evaluated {sort_arrow(:last_evaluated, @sort, @sort_dir)}</th>
              <th class={Theme.class(@theme, :th)}>Schedule</th>
              <th class={Theme.class(@theme, :th)}>Prerequisites</th>
              <th class={Theme.class(@theme, :th)}></th>
            </tr>
          </thead>
          <tbody>
            <%= for {_group, members} <- @groups, {_display, flag} <- members do %>
              <tr class={Theme.class(@theme, :tr)}>
                <td class={Theme.class(@theme, :td)}>
                  <span class={Theme.class(@theme, :name)}>{flag.name}</span>
                </td>
                <td class={Theme.class(@theme, :td)}>{flag_state(flag)}</td>
                <td class={Theme.class(@theme, :td)}>{format_age(@instance, flag.name)}</td>
                <td class={Theme.class(@theme, :td)}>{if has_schedule?(flag), do: "📅", else: "—"}</td>
                <td class={Theme.class(@theme, :td)}>{prerequisite_count(flag)}</td>
                <td class={Theme.class(@theme, :td)}>
                  <button
                    type="button"
                    class={Theme.class(@theme, :icon_button)}
                    phx-click="toggle_row"
                    phx-value-flag={flag.name}
                  >{if expanded?(@expanded, flag), do: "▴", else: "▾"}</button>
                </td>
              </tr>
              <tr :if={expanded?(@expanded, flag)}>
                <td class={Theme.class(@theme, :td)} colspan="6">
                  <div class={Theme.class(@theme, :editor)}>
                    <.flag_editor
                      flag={flag}
                      theme={@theme}
                      actor_drafts={@actor_drafts}
                      group_drafts={@group_drafts}
                      all_flags={@all_flags}
                    />
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
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
      instance = socket.assigns.instance

      if currently_on?(socket, name),
        do: Bandera.disable(flag_name, instance: instance),
        else: Bandera.enable(flag_name, instance: instance)

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
        Bandera.enable(String.to_existing_atom(name),
          for_actor: actor,
          instance: socket.assigns.instance
        )

        {:noreply,
         socket
         |> assign(:flash_error, nil)
         |> update(:actor_drafts, &Map.delete(&1, name))
         |> refresh()}
      end
    end

    def handle_event("remove_actor", %{"flag" => name, "actor" => actor}, socket) do
      Bandera.clear(String.to_existing_atom(name),
        for_actor: actor,
        instance: socket.assigns.instance
      )

      {:noreply, socket |> assign(:flash_error, nil) |> refresh()}
    end

    def handle_event("toggle_actor_gate", %{"flag" => name, "actor" => actor}, socket) do
      flag_name = String.to_existing_atom(name)
      instance = socket.assigns.instance

      if gate_enabled?(socket, name, :actor, actor),
        do: Bandera.disable(flag_name, for_actor: actor, instance: instance),
        else: Bandera.enable(flag_name, for_actor: actor, instance: instance)

      {:noreply, socket |> assign(:flash_error, nil) |> refresh()}
    end

    def handle_event("group_input", %{"flag" => name, "group" => group}, socket) do
      {:noreply, update(socket, :group_drafts, &Map.put(&1, name, group))}
    end

    def handle_event("add_group", %{"flag" => name, "group" => group}, socket) do
      group = String.trim(group)

      if group == "" do
        {:noreply, assign(socket, :flash_error, "Group name can't be blank.")}
      else
        Bandera.enable(String.to_existing_atom(name),
          for_group: group,
          instance: socket.assigns.instance
        )

        {:noreply,
         socket
         |> assign(:flash_error, nil)
         |> update(:group_drafts, &Map.delete(&1, name))
         |> refresh()}
      end
    end

    def handle_event("remove_group", %{"flag" => name, "group" => group}, socket) do
      Bandera.clear(String.to_existing_atom(name),
        for_group: group,
        instance: socket.assigns.instance
      )

      {:noreply, socket |> assign(:flash_error, nil) |> refresh()}
    end

    def handle_event("toggle_group_gate", %{"flag" => name, "group" => group}, socket) do
      flag_name = String.to_existing_atom(name)
      instance = socket.assigns.instance

      if gate_enabled?(socket, name, :group, group),
        do: Bandera.disable(flag_name, for_group: group, instance: instance),
        else: Bandera.enable(flag_name, for_group: group, instance: instance)

      {:noreply, socket |> assign(:flash_error, nil) |> refresh()}
    end

    def handle_event(
          "set_percentage",
          %{"flag" => name, "percent" => percent, "kind" => kind},
          socket
        ) do
      with {pct, ""} <- Integer.parse(String.trim(percent)),
           true <- pct >= 1 and pct <= 99,
           {:ok, gate_kind} <- percentage_kind(kind) do
        Bandera.enable(String.to_existing_atom(name),
          for_percentage_of: {gate_kind, pct / 100},
          instance: socket.assigns.instance
        )

        {:noreply, socket |> assign(:flash_error, nil) |> refresh()}
      else
        _ ->
          {:noreply,
           assign(socket, :flash_error, "Percentage must be a whole number between 1 and 99.")}
      end
    end

    def handle_event("clear_percentage", %{"flag" => name}, socket) do
      Bandera.clear(String.to_existing_atom(name),
        for_percentage: true,
        instance: socket.assigns.instance
      )

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

        Bandera.put_variants(String.to_existing_atom(name), weights,
          instance: socket.assigns.instance
        )

        {:noreply, socket |> assign(:flash_error, nil) |> refresh()}
      else
        _ ->
          {:noreply, assign(socket, :flash_error, "Variant needs a name and a positive weight.")}
      end
    end

    def handle_event("remove_variant", %{"flag" => name, "variant" => variant}, socket) do
      flag_name = String.to_existing_atom(name)
      weights = name |> current_weights(socket) |> Map.delete(variant)
      instance = socket.assigns.instance

      if map_size(weights) == 0,
        do: Bandera.clear(flag_name, variant: true, instance: instance),
        else: Bandera.put_variants(flag_name, weights, instance: instance)

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

        Bandera.enable(String.to_existing_atom(name),
          when: constraints,
          instance: socket.assigns.instance
        )

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
          instance = socket.assigns.instance

          if constraints == [],
            do: Bandera.clear(flag_name, rule: true, instance: instance),
            else: Bandera.enable(flag_name, when: constraints, instance: instance)

          {:noreply, socket |> assign(:flash_error, nil) |> refresh()}

        _ ->
          {:noreply, socket}
      end
    end

    def handle_event("add_segment", %{"flag" => name, "segment" => segment}, socket) do
      case String.trim(segment) do
        "" ->
          {:noreply, assign(socket, :flash_error, "Segment name can't be blank.")}

        seg ->
          Bandera.enable(String.to_existing_atom(name),
            for_segment: seg,
            instance: socket.assigns.instance
          )

          {:noreply, socket |> assign(:flash_error, nil) |> refresh()}
      end
    end

    def handle_event("remove_segment", %{"flag" => name, "segment" => segment}, socket) do
      Bandera.clear(String.to_existing_atom(name),
        for_segment: segment,
        instance: socket.assigns.instance
      )

      {:noreply, socket |> assign(:flash_error, nil) |> refresh()}
    end

    def handle_event(
          "add_prerequisite",
          %{"flag" => name, "parent" => parent, "required" => required},
          socket
        ) do
      case String.trim(parent) do
        "" ->
          {:noreply, assign(socket, :flash_error, "Pick a prerequisite flag.")}

        parent ->
          Bandera.enable(String.to_existing_atom(name),
            requires: {String.to_existing_atom(parent), required == "on"},
            instance: socket.assigns.instance
          )

          {:noreply, socket |> assign(:flash_error, nil) |> refresh()}
      end
    end

    def handle_event("remove_prerequisite", %{"flag" => name, "parent" => parent}, socket) do
      Bandera.clear(String.to_existing_atom(name),
        requires: String.to_existing_atom(parent),
        instance: socket.assigns.instance
      )

      {:noreply, socket |> assign(:flash_error, nil) |> refresh()}
    end

    def handle_event("set_schedule", %{"flag" => name, "from" => from, "until" => until}, socket) do
      from = blank_to_nil(from)
      until = blank_to_nil(until)

      if is_nil(from) and is_nil(until) do
        {:noreply, assign(socket, :flash_error, "Set a start or an end for the schedule.")}
      else
        Bandera.enable(String.to_existing_atom(name),
          schedule: {from, until},
          instance: socket.assigns.instance
        )

        {:noreply, socket |> assign(:flash_error, nil) |> refresh()}
      end
    end

    def handle_event("clear_schedule", %{"flag" => name}, socket) do
      Bandera.clear(String.to_existing_atom(name),
        schedule: true,
        instance: socket.assigns.instance
      )

      {:noreply, socket |> assign(:flash_error, nil) |> refresh()}
    end

    @create_name_regex ~r/^[a-z][a-z0-9_.]*$/
    def handle_event("create_flag", %{"flag_name" => raw}, socket) do
      name = String.trim(raw)

      cond do
        name == "" ->
          {:noreply, assign(socket, :create_error, "Flag name can't be blank.")}

        String.length(name) > 64 ->
          {:noreply, assign(socket, :create_error, "Flag name must be 64 characters or fewer.")}

        not Regex.match?(@create_name_regex, name) ->
          {:noreply,
           assign(
             socket,
             :create_error,
             "Invalid name. Use lowercase letters, digits, dots, and underscores; must start with a letter."
           )}

        true ->
          # String.to_atom is safe here: input is restricted to at most 64 characters
          # matching ~r/^[a-z][a-z0-9_.]*$/, only reachable from an authenticated dashboard session.
          flag_atom = String.to_atom(name)

          case Bandera.disable(flag_atom, instance: socket.assigns.instance) do
            {:ok, _} ->
              {:noreply, socket |> assign(:create_error, nil) |> refresh()}

            {:error, reason} ->
              {:noreply,
               assign(socket, :create_error, "Failed to create flag: #{inspect(reason)}")}
          end
      end
    end

    def handle_event("sort", %{"col" => col}, socket) do
      new_sort = parse_sort(col)

      new_dir =
        if new_sort == socket.assigns.sort,
          do: if(socket.assigns.sort_dir == :asc, do: :desc, else: :asc),
          else: :asc

      {:noreply, socket |> assign(sort: new_sort, sort_dir: new_dir) |> recompute_groups()}
    end

    def handle_event("clear_flag", %{"flag" => name}, socket) do
      flag_name = String.to_existing_atom(name)
      Bandera.clear(flag_name, instance: socket.assigns.instance)

      {:noreply,
       socket
       |> update(:expanded, &MapSet.delete(&1, name))
       |> refresh()}
    end

    @impl true
    def handle_info({:bandera_change, _flag, _id}, socket) do
      {:noreply, refresh(socket)}
    end

    def handle_info(:refresh_usage, socket) do
      socket = refresh_usage(socket)

      if socket.assigns.usage_status == :loading do
        schedule_usage_refresh()
      end

      {:noreply, socket}
    end

    def handle_info(_msg, socket), do: {:noreply, socket}

    # ---- assigns helpers ----

    defp load_flags(socket) do
      instance = socket.assigns.instance

      flags =
        case Bandera.all_flags(instance: instance) do
          {:ok, flags} -> flags
          {:error, _} -> []
        end

      flag_names = Enum.map(flags, & &1.name)
      similar = Bandera.Dashboard.Similarity.similar_pairs(flag_names)

      socket
      |> assign(:all_flags, flags)
      |> assign(:similar_pairs, similar)
      |> recompute_groups()
    end

    defp recompute_groups(socket) do
      separator =
        if socket.assigns.grouped and socket.assigns.view == :cards,
          do: Bandera.Config.get(socket.assigns.instance).group_separator,
          else: nil

      filtered =
        for flag <- socket.assigns.all_flags,
            matches?(flag, socket.assigns.search),
            do: flag

      grouped = Bandera.Dashboard.Grouping.group(filtered, separator)

      groups =
        if socket.assigns.view == :table do
          apply_table_sort(
            socket.assigns.instance,
            grouped,
            socket.assigns.sort,
            socket.assigns.sort_dir
          )
        else
          grouped
        end

      assign(socket, :groups, groups)
    end

    defp apply_table_sort(instance, groups, sort, dir) do
      Enum.map(groups, fn {group, members} ->
        sorted =
          case sort do
            :name ->
              Enum.sort_by(members, fn {_display, flag} -> to_string(flag.name) end, dir)

            :state ->
              Enum.sort_by(members, fn {_display, flag} -> flag_state_sort_key(flag) end, dir)

            :last_evaluated ->
              Enum.sort_by(
                members,
                fn {_display, flag} ->
                  case Bandera.Dashboard.Stale.age_days(instance, flag.name) do
                    :never -> nil
                    {:ok, days} -> days
                  end
                end,
                fn
                  nil, nil -> true
                  nil, _ -> true
                  _, nil -> false
                  a, b -> if dir == :asc, do: a >= b, else: a <= b
                end
              )
          end

        {group, sorted}
      end)
    end

    defp flag_state_sort_key(flag) do
      case flag_state(flag) do
        "on" -> 0
        "partial" -> 1
        "off" -> 2
      end
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

    @constraint_operators ~w(eq neq in not_in contains gt gte lt lte matches)a

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

    # Whether the actor/group gate for `target` on flag `name` is currently a
    # grant (true) vs a deny (false/absent). Used to decide which way to toggle.
    defp gate_enabled?(socket, name, type, target) do
      Enum.any?(socket.assigns.all_flags, fn flag ->
        to_string(flag.name) == name and
          Enum.any?(flag.gates, fn g ->
            g.type == type and to_string(g.for) == to_string(target) and g.enabled
          end)
      end)
    end

    defp refresh(socket) do
      socket
      |> load_flags()
      |> refresh_usage()
    end

    defp refresh_usage(socket) do
      instance = socket.assigns.instance

      assign(socket,
        stale_set: Bandera.Dashboard.Stale.stale_set(instance),
        usage_status: Bandera.Dashboard.Stale.usage_status(instance)
      )
    end

    defp parse_sort("last_evaluated"), do: :last_evaluated
    defp parse_sort("state"), do: :state
    defp parse_sort(_), do: :name

    defp subscribe_to_changes(conf) do
      with true <- conf.notifications_adapter == Bandera.Notifications.PhoenixPubSub,
           client when not is_nil(client) <- Keyword.get(conf.notifications, :client) do
        Phoenix.PubSub.subscribe(client, Bandera.Notifications.topic(conf))
      else
        _ -> :ok
      end
    end

    defp schedule_usage_refresh,
      do: Process.send_after(self(), :refresh_usage, @usage_refresh_interval)

    defp percentage_kind("actors"), do: {:ok, :actors}
    defp percentage_kind("time"), do: {:ok, :time}
    defp percentage_kind(_), do: :error

    defp blank_to_nil(str) do
      case String.trim(str) do
        "" -> nil
        s -> s
      end
    end

    defp has_schedule?(flag), do: Enum.any?(flag.gates, &Bandera.Gate.schedule?/1)
    defp has_prerequisites?(flag), do: Enum.any?(flag.gates, &Bandera.Gate.prerequisite?/1)

    defp flag_state(flag) do
      cond do
        boolean_on?(flag) -> "on"
        Enum.any?(flag.gates, fn g -> g.type == :boolean and not g.enabled end) -> "off"
        flag.gates == [] -> "off"
        true -> "partial"
      end
    end

    defp format_age(instance, flag_name) do
      case Bandera.Dashboard.Stale.age_days(instance, flag_name) do
        :never -> "—"
        {:ok, days} -> "#{days}d ago"
      end
    end

    defp prerequisite_count(flag) do
      case Enum.count(flag.gates, &Bandera.Gate.prerequisite?/1) do
        0 -> "—"
        n -> to_string(n)
      end
    end

    defp sort_arrow(col, col, :asc), do: "▴"
    defp sort_arrow(col, col, :desc), do: "▾"
    defp sort_arrow(_col, _sort, _dir), do: ""
  end
end
