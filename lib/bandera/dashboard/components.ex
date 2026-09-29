if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Bandera.Dashboard.Components do
    @moduledoc "Function components for the Bandera dashboard."
    use Phoenix.Component

    alias Bandera.Dashboard.Theme
    alias Bandera.Gate

    # Self-contained, `bandera-`-prefixed stylesheet for the standalone theme.
    # Colors/radii are read as `var(--bandera-*, <default>)` and never declared
    # here, so a consumer retheme is a one-liner with no specificity fight:
    # `:root { --bandera-primary: #0ea5e9 }`. Defaults are a fixed light palette;
    # for dark mode set the variables, or use the `:daisyui` theme.
    @dashboard_css """
    .bandera-wrap *, .bandera-wrap *::before, .bandera-wrap *::after { box-sizing: border-box; }
    .bandera-wrap {
      max-width: 880px; margin: 0 auto; padding: 24px 16px; line-height: 1.5;
      font-family: var(--bandera-font, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif);
      color: var(--bandera-fg, #1f2937);
    }
    .bandera-heading { font-size: 22px; font-weight: 700; letter-spacing: -0.01em; margin: 0 0 18px; }

    .bandera-search {
      width: 100%; padding: 10px 12px; font-size: 14px; color: inherit; margin-bottom: 18px;
      background: var(--bandera-surface, #ffffff);
      border: 1px solid var(--bandera-border, #e2e8f0);
      border-radius: var(--bandera-radius, 10px);
    }
    .bandera-search:focus-visible {
      outline: 2px solid var(--bandera-primary, #6d28d9); outline-offset: 1px; border-color: transparent;
    }

    .bandera-group { margin-bottom: 8px; }
    .bandera-group-summary {
      cursor: pointer; list-style: none; user-select: none;
      display: flex; align-items: center; gap: 7px; padding: 8px 2px;
      font-size: 12px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.05em;
      color: var(--bandera-primary, #6d28d9);
    }
    .bandera-group-summary::-webkit-details-marker { display: none; }
    .bandera-group-summary::before {
      content: "\\25B8"; font-size: 11px; transition: transform 0.15s ease;
      color: var(--bandera-muted, #94a3b8);
    }
    .bandera-group[open] > .bandera-group-summary::before { transform: rotate(90deg); }
    .bandera-count {
      color: var(--bandera-muted, #94a3b8); font-weight: 400; text-transform: none; letter-spacing: 0;
    }

    .bandera-row {
      display: flex; align-items: center; justify-content: space-between; gap: 12px;
      padding: 11px 14px; margin: 8px 0;
      background: var(--bandera-surface, #ffffff);
      border: 1px solid var(--bandera-border, #e2e8f0);
      border-radius: var(--bandera-radius, 10px);
      box-shadow: var(--bandera-shadow, 0 1px 2px rgba(15, 23, 42, 0.05));
    }
    .bandera-name { font-weight: 600; }
    .bandera-summary { color: var(--bandera-muted, #64748b); font-size: 13px; margin-left: 10px; }

    .bandera-editor {
      padding: 14px; margin: 2px 0 10px;
      background: var(--bandera-surface-2, #f8fafc);
      border: 1px solid var(--bandera-border, #e2e8f0);
      border-radius: var(--bandera-radius, 10px);
    }
    .bandera-editor form { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
    .bandera-editor form .bandera-input[type="text"] { flex: 1 1 160px; }
    .bandera-input[type="number"] { width: 92px; }
    .bandera-fieldset {
      margin: 0 0 14px; padding: 12px 14px 14px;
      border: 1px solid var(--bandera-border, #e2e8f0);
      border-radius: var(--bandera-radius-sm, 8px);
    }
    .bandera-fieldset:last-of-type { margin-bottom: 12px; }
    .bandera-legend {
      font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; padding: 0 4px;
      color: var(--bandera-muted, #94a3b8);
    }
    .bandera-gate-list {
      list-style: none; padding: 0; margin: 6px 0 10px; display: flex; flex-direction: column; gap: 5px;
    }
    .bandera-gate-item { display: flex; align-items: center; gap: 8px; }
    .bandera-gate-item code {
      font-size: 12px; padding: 2px 7px; border-radius: 6px;
      background: var(--bandera-surface-2, #f1f5f9);
    }

    .bandera-input, .bandera-select {
      padding: 7px 10px; font-size: 13px; color: inherit;
      background: var(--bandera-surface, #ffffff);
      border: 1px solid var(--bandera-border, #e2e8f0);
      border-radius: var(--bandera-radius-sm, 8px);
    }
    .bandera-input:focus-visible, .bandera-select:focus-visible {
      outline: 2px solid var(--bandera-primary, #6d28d9); outline-offset: 1px; border-color: transparent;
    }

    .bandera-primary, .bandera-danger, .bandera-btn, .bandera-icon-btn {
      font: inherit; font-size: 13px; font-weight: 500; cursor: pointer; padding: 7px 13px;
      border: 1px solid transparent; border-radius: var(--bandera-radius-sm, 8px);
      transition: filter 0.12s ease, background 0.12s ease;
    }
    .bandera-primary { background: var(--bandera-primary, #6d28d9); color: var(--bandera-primary-fg, #ffffff); }
    .bandera-primary:hover { filter: brightness(1.08); }
    .bandera-btn {
      color: inherit;
      background: var(--bandera-surface, #ffffff);
      border-color: var(--bandera-border, #e2e8f0);
    }
    .bandera-btn:hover { background: var(--bandera-surface-2, #f8fafc); }
    .bandera-danger {
      background: transparent;
      color: var(--bandera-danger, #dc2626);
      border-color: var(--bandera-danger-border, #fecaca);
    }
    .bandera-danger:hover { background: var(--bandera-danger-bg, #fef2f2); }
    .bandera-icon-btn {
      padding: 6px 9px; background: transparent; border-color: transparent;
      color: var(--bandera-muted, #94a3b8);
    }
    .bandera-icon-btn:hover { color: inherit; background: var(--bandera-surface-2, #f1f5f9); }

    .bandera-toggle {
      appearance: none; -webkit-appearance: none; box-sizing: border-box;
      position: relative; flex: none; display: inline-block; vertical-align: middle;
      width: 44px; height: 24px; padding: 0; border: none; border-radius: 999px;
      cursor: pointer; font-size: 0; color: transparent;
      background: var(--bandera-success, #16a34a);
      transition: background 0.15s ease;
    }
    .bandera-toggle::before {
      content: ""; position: absolute; top: 3px; left: 3px;
      width: 18px; height: 18px; border-radius: 50%; background: #ffffff;
      box-shadow: 0 1px 2px rgba(15, 23, 42, 0.25);
      transition: transform 0.15s ease; transform: translateX(20px);
    }
    .bandera-toggle:focus-visible {
      outline: 2px solid var(--bandera-primary, #6d28d9); outline-offset: 2px;
    }
    .bandera-toggle.bandera-off { background: var(--bandera-off, #cbd5e1); }
    .bandera-toggle.bandera-off::before { transform: translateX(0); }

    .bandera-flash {
      padding: 10px 12px; margin-bottom: 14px; font-size: 14px;
      color: var(--bandera-danger, #dc2626);
      background: var(--bandera-danger-bg, #fef2f2);
      border: 1px solid var(--bandera-danger-border, #fecaca);
      border-radius: var(--bandera-radius-sm, 8px);
    }
    .bandera-flash-warn {
      padding: 10px 12px; margin-bottom: 14px; font-size: 14px;
      color: var(--bandera-warn-fg, #92400e);
      background: var(--bandera-warn-bg, #fffbeb);
      border: 1px solid var(--bandera-warn-border, #fde68a);
      border-radius: var(--bandera-radius-sm, 8px);
    }
    .bandera-icon-hint { font-size: 13px; margin-left: 6px; cursor: default; }
    .bandera-hint {
      font-size: 12px; line-height: 1.5;
      color: var(--bandera-muted, #64748b);
      background: var(--bandera-hint-bg, #f8fafc);
      border-radius: var(--bandera-radius-sm, 8px);
      padding: 8px 10px; margin-bottom: 10px;
    }
    .bandera-full-name {
      font-size: 11px; font-weight: 400;
      color: var(--bandera-muted, #94a3b8);
      display: block; margin-top: 1px;
    }
    .bandera-view-controls {
      display: flex; gap: 16px; align-items: center; margin-bottom: 18px; font-size: 13px;
    }
    .bandera-view-toggle {
      padding: 5px 11px; border-radius: var(--bandera-radius-sm, 8px);
      border: 1px solid var(--bandera-border, #e2e8f0);
      color: var(--bandera-muted, #94a3b8); text-decoration: none; font-size: 13px;
    }
    .bandera-view-toggle--active {
      background: var(--bandera-primary, #6d28d9);
      color: var(--bandera-primary-fg, #ffffff); border-color: transparent;
    }
    .bandera-grouping-toggle { color: var(--bandera-muted, #94a3b8); text-decoration: none; font-size: 13px; }
    .bandera-table { width: 100%; border-collapse: collapse; margin-top: 8px; }
    .bandera-th {
      text-align: left; padding: 8px 12px; font-size: 11px; font-weight: 700;
      text-transform: uppercase; letter-spacing: 0.05em;
      color: var(--bandera-muted, #94a3b8);
      border-bottom: 2px solid var(--bandera-border, #e2e8f0);
    }
    .bandera-th--sortable { cursor: pointer; }
    .bandera-th--sortable:hover { color: var(--bandera-fg, #1f2937); }
    .bandera-td {
      padding: 10px 12px; font-size: 14px;
      border-bottom: 1px solid var(--bandera-border, #e2e8f0);
      vertical-align: middle;
    }
    .bandera-tr:hover > .bandera-td { background: var(--bandera-surface-2, #f8fafc); }
    .bandera-create-form { display: flex; gap: 8px; align-items: center; margin-bottom: 14px; }
    .bandera-create-form .bandera-input { flex: 1 1 200px; }
    .bandera-similarity-warning {
      padding: 10px 14px; margin-bottom: 14px; font-size: 13px;
      color: var(--bandera-warn-fg, #92400e);
      background: var(--bandera-warn-bg, #fffbeb);
      border: 1px solid var(--bandera-warn-border, #fde68a);
      border-radius: var(--bandera-radius-sm, 8px);
    }
    .bandera-similarity-warning ul { margin: 6px 0 0; padding-left: 18px; }
    .bandera-similarity-warning li { margin-bottom: 2px; }
    """

    @doc """
    Renders the dashboard's self-contained, prefixed stylesheet as a `<style>`
    block. In `:daisyui` theme it renders nothing — the host app supplies the
    styles via its own daisyUI build.
    """
    attr(:theme, :atom, default: :standalone)
    @spec styles(map()) :: Phoenix.LiveView.Rendered.t()
    def styles(assigns) do
      # HEEx treats <style> bodies as verbatim text, so the CSS can't be
      # interpolated inside a `<style>` tag in the template. Build the whole
      # tag as a safe value (CSS is a compile-time constant, never user input)
      # and render it at the template root instead.
      style_tag =
        if assigns.theme == :daisyui,
          do: nil,
          else: Phoenix.HTML.raw("<style>#{@dashboard_css}</style>")

      assigns = assign(assigns, :style_tag, style_tag)

      ~H"""
      {@style_tag}
      """
    end

    @doc "Renders a human-readable summary of a flag's active gates."
    attr(:flag, :map, required: true)
    attr(:theme, :atom, default: :standalone)

    @spec state_summary(map()) :: Phoenix.LiveView.Rendered.t()
    def state_summary(assigns) do
      assigns = assign(assigns, :parts, summary_parts(assigns.flag.gates))

      ~H"""
      <span class={Theme.class(@theme, :summary)}>
        {if @parts == [], do: "no gates", else: Enum.join(@parts, " · ")}
      </span>
      """
    end

    @doc """
    Renders an amber warning banner when usage history is unavailable or loading.
    `instance` names the dashboard's bound instance, used only to tailor the
    "not running" hint (the default instance keeps its historical wording).
    """
    attr(:theme, :atom, default: :standalone)
    attr(:status, :atom, required: true)
    attr(:instance, :atom, default: Bandera.Config.default_instance())

    @spec usage_warning(map()) :: Phoenix.LiveView.Rendered.t()
    def usage_warning(assigns) do
      assigns = assign(assigns, :usage_child_spec, usage_child_spec(assigns.instance))

      ~H"""
      <div class={Theme.class(@theme, :flash_warn)}>
        <%= if @status == :loading do %>
          Usage history is loading. Stale and never-evaluated indicators will appear once
          persisted history is available.
        <% else %>
          Stale flag detection is unavailable. Add <code>{@usage_child_spec}</code> to your
          supervision tree to enable it.
          <a href="https://hexdocs.pm/bandera/Bandera.Usage.html" target="_blank" rel="noopener">
            See the documentation →
          </a>
        <% end %>
      </div>
      """
    end

    defp usage_child_spec(instance) do
      if instance == Bandera.Config.default_instance(),
        do: "Bandera.Usage",
        else: "{Bandera.Usage, instance: #{inspect(instance)}}"
    end

    attr(:pairs, :list, required: true)
    attr(:theme, :atom, default: :standalone)

    @spec similarity_warning(map()) :: Phoenix.LiveView.Rendered.t()
    def similarity_warning(assigns) do
      ~H"""
      <div :if={@pairs != []} class={Theme.class(@theme, :similarity_warning)}>
        <strong>Possible typos detected</strong> — one of each pair may be a typo of the other.
        <ul>
          <li :for={{a, b, score} <- @pairs}>
            <code>:{a}</code> and <code>:{b}</code>
            <span>(score: {Float.round(score, 2)})</span>
          </li>
        </ul>
      </div>
      """
    end

    @doc "Renders a stale hint icon with age for a flag known to be stale."
    attr(:flag_name, :atom, required: true)
    attr(:theme, :atom, default: :standalone)
    attr(:instance, :atom, default: Bandera.Config.default_instance())

    @spec stale_indicator(map()) :: Phoenix.LiveView.Rendered.t()
    def stale_indicator(assigns) do
      assigns = assign(assigns, :label, stale_label(assigns.instance, assigns.flag_name))

      ~H"""
      <span class={Theme.class(@theme, :icon_hint)} title={@label}>⚠</span>
      """
    end

    defp stale_label(instance, flag_name) do
      case Bandera.Dashboard.Stale.age_days(instance, flag_name) do
        :never -> "Never evaluated"
        {:ok, days} -> "Stale — last seen #{days}d ago"
      end
    end

    defp summary_parts(gates) do
      [
        boolean_part(gates),
        percentage_part(gates),
        count_part(gates, &Gate.actor?/1, "actor"),
        count_part(gates, &Gate.group?/1, "group"),
        variant_part(gates),
        rule_part(gates),
        count_part(gates, &Gate.segment?/1, "segment"),
        count_part(gates, &Gate.prerequisite?/1, "prerequisite"),
        schedule_part(gates)
      ]
      |> Enum.reject(&is_nil/1)
    end

    defp boolean_part(gates) do
      case Enum.find(gates, &Gate.boolean?/1) do
        nil -> nil
        %Gate{enabled: true} -> "on"
        %Gate{enabled: false} -> "off"
      end
    end

    defp percentage_part(gates) do
      cond do
        gate = Enum.find(gates, &Gate.percentage_of_actors?/1) ->
          "#{percent(gate.for)}% of actors"

        gate = Enum.find(gates, &Gate.percentage_of_time?/1) ->
          "#{percent(gate.for)}% of time"

        true ->
          nil
      end
    end

    defp variant_part(gates) do
      case Enum.find(gates, &Gate.variant?/1) do
        nil ->
          nil

        %Gate{value: weights} ->
          total = weights |> Map.values() |> Enum.sum()

          parts =
            weights
            |> Enum.sort_by(fn {name, _w} -> name end)
            |> Enum.map_join(", ", fn {name, w} -> "#{name} #{percent(w / total)}%" end)

          "variants " <> parts
      end
    end

    defp rule_part(gates) do
      case Enum.find(gates, &Gate.rule?/1) do
        nil ->
          nil

        %Gate{value: constraints} ->
          n = length(constraints)
          noun = if n == 1, do: "constraint", else: "constraints"
          "rule (#{n} #{noun})"
      end
    end

    defp schedule_part(gates) do
      case Enum.find(gates, &Gate.schedule?/1) do
        nil ->
          nil

        %Gate{value: %{"from" => from, "until" => until}} ->
          cond do
            from && until -> "scheduled #{from} → #{until}"
            from -> "scheduled from #{from}"
            until -> "scheduled until #{until}"
            true -> "scheduled"
          end
      end
    end

    defp count_part(gates, pred, noun) do
      case Enum.count(gates, pred) do
        0 -> nil
        1 -> "1 #{noun}"
        n -> "#{n} #{noun}s"
      end
    end

    defp percent(ratio), do: round(ratio * 100)

    @doc "Renders the gate editor panel for a flag. Event handlers live in FlagsLive."
    attr(:flag, :map, required: true)
    attr(:theme, :atom, default: :standalone)
    attr(:actor_drafts, :map, default: %{})
    attr(:group_drafts, :map, default: %{})
    attr(:all_flags, :list, default: [])

    @spec flag_editor(map()) :: Phoenix.LiveView.Rendered.t()
    def flag_editor(assigns) do
      ~H"""
      <div class={Theme.class(@theme, :hint)}>
        <strong>How gates combine:</strong>
        An actor setting always wins over a group setting (a user turned <em>on</em>
        individually stays on even if their group is <em>off</em>). Among groups,
        <em>on</em> beats <em>off</em> — a user in any allowed group is in.
        Use the on/off toggles to grant or deny without removing the gate.
      </div>

      <fieldset class={Theme.class(@theme, :fieldset)}>
        <legend class={Theme.class(@theme, :legend)}>Actors</legend>
        <ul class={Theme.class(@theme, :gate_list)}>
          <li :for={{id, enabled} <- actor_targets(@flag)} class={Theme.class(@theme, :gate_item)}>
            <code>{id}</code>
            <button
              type="button"
              class={Theme.class(@theme, if(enabled, do: :toggle_on, else: :toggle_off))}
              phx-click="toggle_actor_gate"
              phx-value-flag={@flag.name}
              phx-value-actor={id}
            >{if enabled, do: "on", else: "off"}</button>
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
          <li :for={{name, enabled} <- group_targets(@flag)} class={Theme.class(@theme, :gate_item)}>
            <code>{name}</code>
            <button
              type="button"
              class={Theme.class(@theme, if(enabled, do: :toggle_on, else: :toggle_off))}
              phx-click="toggle_group_gate"
              phx-value-flag={@flag.name}
              phx-value-group={name}
            >{if enabled, do: "on", else: "off"}</button>
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
          <input type="number" name="percent" min="1" max="99" placeholder="%" class={Theme.class(@theme, :input)} />
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
          >clear</button>
        </form>
      </fieldset>

      {render_variants(assigns, @flag)}
      {render_rule(assigns, @flag)}
      {render_segments(assigns, @flag)}
      {render_prerequisites(assigns, @flag)}
      {render_schedule(assigns, @flag)}

      <button
        type="button"
        class={Theme.class(@theme, :danger_button)}
        phx-click="clear_flag"
        phx-value-flag={@flag.name}
      >Clear whole flag</button>
      """
    end

    @constraint_operators ~w(eq neq in not_in contains gt gte lt lte matches)a

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

    defp render_segments(assigns, flag) do
      assigns = Phoenix.Component.assign(assigns, :flag, flag)

      ~H"""
      <fieldset class={Theme.class(@theme, :fieldset)}>
        <legend class={Theme.class(@theme, :legend)}>Segments</legend>
        <ul class={Theme.class(@theme, :gate_list)}>
          <li :for={seg <- segment_targets(@flag)} class={Theme.class(@theme, :gate_item)}>
            <code>{seg}</code>
            <button
              type="button"
              class={Theme.class(@theme, :danger_button)}
              phx-click="remove_segment"
              phx-value-flag={@flag.name}
              phx-value-segment={seg}
            >remove</button>
          </li>
        </ul>
        <form phx-submit="add_segment">
          <input type="hidden" name="flag" value={@flag.name} />
          <input type="text" name="segment" placeholder="segment name" class={Theme.class(@theme, :input)} />
          <button class={Theme.class(@theme, :primary_button)}>add segment</button>
        </form>
      </fieldset>
      """
    end

    defp render_prerequisites(assigns, flag) do
      assigns =
        assigns
        |> Phoenix.Component.assign(:flag, flag)
        |> Phoenix.Component.assign(:candidates, prerequisite_candidates(assigns.all_flags, flag))

      ~H"""
      <fieldset class={Theme.class(@theme, :fieldset)}>
        <legend class={Theme.class(@theme, :legend)}>Prerequisites</legend>
        <ul class={Theme.class(@theme, :gate_list)}>
          <li :for={g <- prerequisite_gates(@flag)} class={Theme.class(@theme, :gate_item)}>
            <code>{g.for} (must be {if g.enabled, do: "on", else: "off"})</code>
            <button
              type="button"
              class={Theme.class(@theme, :danger_button)}
              phx-click="remove_prerequisite"
              phx-value-flag={@flag.name}
              phx-value-parent={g.for}
            >remove</button>
          </li>
        </ul>
        <form phx-submit="add_prerequisite">
          <input type="hidden" name="flag" value={@flag.name} />
          <select name="parent" class={Theme.class(@theme, :select)}>
            <option value="">flag…</option>
            <option :for={f <- @candidates} value={f}>{f}</option>
          </select>
          <select name="required" class={Theme.class(@theme, :select)}>
            <option value="on">on</option>
            <option value="off">off</option>
          </select>
          <button class={Theme.class(@theme, :primary_button)}>add prerequisite</button>
        </form>
      </fieldset>
      """
    end

    defp render_schedule(assigns, flag) do
      assigns =
        assigns
        |> Phoenix.Component.assign(:flag, flag)
        |> Phoenix.Component.assign(:window, schedule_window(flag))

      ~H"""
      <fieldset class={Theme.class(@theme, :fieldset)}>
        <legend class={Theme.class(@theme, :legend)}>Schedule</legend>
        <form phx-submit="set_schedule">
          <input type="hidden" name="flag" value={@flag.name} />
          <input
            type="text"
            name="from"
            value={@window["from"]}
            placeholder="from (ISO 8601)"
            class={Theme.class(@theme, :input)}
          />
          <input
            type="text"
            name="until"
            value={@window["until"]}
            placeholder="until (ISO 8601)"
            class={Theme.class(@theme, :input)}
          />
          <button class={Theme.class(@theme, :primary_button)}>set</button>
          <button
            type="button"
            class={Theme.class(@theme, :neutral_button)}
            phx-click="clear_schedule"
            phx-value-flag={@flag.name}
          >clear</button>
        </form>
      </fieldset>
      """
    end

    defp actor_targets(flag) do
      for(g <- flag.gates, Bandera.Gate.actor?(g), do: {g.for, g.enabled}) |> Enum.sort()
    end

    defp group_targets(flag) do
      for(g <- flag.gates, Bandera.Gate.group?(g), do: {g.for, g.enabled}) |> Enum.sort()
    end

    defp segment_targets(flag), do: for(g <- flag.gates, Bandera.Gate.segment?(g), do: g.for)

    defp prerequisite_gates(flag), do: for(g <- flag.gates, Bandera.Gate.prerequisite?(g), do: g)

    defp prerequisite_candidates(all_flags, flag),
      do: for(f <- all_flags, f.name != flag.name, do: f.name)

    defp variant_weights(flag) do
      case Enum.find(flag.gates, &Bandera.Gate.variant?/1) do
        nil -> %{}
        gate -> gate.value
      end
    end

    defp rule_constraints(flag) do
      case Enum.find(flag.gates, &Bandera.Gate.rule?/1) do
        nil -> []
        gate -> gate.value
      end
    end

    defp schedule_window(flag) do
      case Enum.find(flag.gates, &Bandera.Gate.schedule?/1) do
        nil -> %{"from" => nil, "until" => nil}
        gate -> gate.value
      end
    end
  end
end
