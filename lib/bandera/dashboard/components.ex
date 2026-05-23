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
  end
end
