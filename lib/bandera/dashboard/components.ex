if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Bandera.Dashboard.Components do
    @moduledoc "Function components for the Bandera dashboard."
    use Phoenix.Component

    alias Bandera.Gate

    @dashboard_css """
    .bandera-wrap *, .bandera-wrap *::before, .bandera-wrap *::after { box-sizing: border-box; }
    .bandera-wrap { max-width: 880px; margin: 0 auto; padding: 24px 16px;
      font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; color: #1f2937; }
    .bandera-wrap h1 { font-size: 20px; margin: 0 0 16px; }
    .bandera-search { width: 100%; padding: 8px 10px; font-size: 14px; border: 1px solid #d6dae2;
      border-radius: 6px; margin-bottom: 16px; }
    .bandera-group > summary { cursor: pointer; font-weight: 700; color: #6d28d9; padding: 6px 0;
      list-style: none; }
    .bandera-group > summary::-webkit-details-marker { display: none; }
    .bandera-count { color: #94a3b8; font-weight: 400; }
    .bandera-row { display: flex; align-items: center; justify-content: space-between;
      border: 1px solid #e2e5ec; border-radius: 8px; padding: 8px 12px; margin: 6px 0; background: #fff; }
    .bandera-row .bandera-name { font-weight: 600; }
    .bandera-summary { color: #64748b; font-size: 13px; margin-left: 10px; }
    .bandera-editor { border: 1px solid #e2e5ec; border-top: none; border-radius: 0 0 8px 8px;
      padding: 12px; margin: -6px 0 6px; background: #fafbfc; }
    .bandera-editor fieldset { border: 1px dashed #d6dae2; border-radius: 6px; margin: 8px 0; padding: 8px; }
    .bandera-editor legend { font-size: 12px; text-transform: uppercase; color: #94a3b8; }
    .bandera-editor input[type=text], .bandera-editor input[type=number], .bandera-editor select {
      padding: 5px 8px; border: 1px solid #d6dae2; border-radius: 5px; font-size: 13px; }
    .bandera-wrap button { font: inherit; cursor: pointer; border-radius: 5px; border: 1px solid #d6dae2;
      background: #fff; padding: 5px 10px; }
    .bandera-wrap button.bandera-primary { background: #6d28d9; border-color: #6d28d9; color: #fff; }
    .bandera-wrap button.bandera-danger { color: #b91c1c; border-color: #fca5a5; }
    .bandera-toggle { background: #34d399; color: #fff; border: none !important; border-radius: 12px;
      padding: 4px 12px; }
    .bandera-toggle.bandera-off { background: #cbd5e1; color: #475569; }
    .bandera-flash { background: #fef2f2; color: #b91c1c; border: 1px solid #fca5a5;
      border-radius: 6px; padding: 8px 12px; margin-bottom: 12px; }
    ul.bandera-gate-list { list-style: none; padding: 0; margin: 6px 0 0; }
    ul.bandera-gate-list li { display: flex; align-items: center; gap: 8px; padding: 2px 0; }
    """

    @doc "Renders the dashboard's self-contained, prefixed stylesheet as a <style> block."
    @spec styles(map()) :: Phoenix.LiveView.Rendered.t()
    def styles(assigns) do
      # HEEx treats <style> bodies as verbatim text, so the CSS can't be
      # interpolated inside a `<style>` tag in the template. Build the whole
      # tag as a safe value (CSS is a compile-time constant, never user input)
      # and render it at the template root instead.
      assigns = assign(assigns, :style_tag, Phoenix.HTML.raw("<style>#{@dashboard_css}</style>"))

      ~H"""
      {@style_tag}
      """
    end

    @doc "Renders a human-readable summary of a flag's active gates."
    attr(:flag, :map, required: true)

    @spec state_summary(map()) :: Phoenix.LiveView.Rendered.t()
    def state_summary(assigns) do
      assigns = assign(assigns, :parts, summary_parts(assigns.flag.gates))

      ~H"""
      <span class="bandera-summary">
        {if @parts == [], do: "no gates", else: Enum.join(@parts, " · ")}
      </span>
      """
    end

    defp summary_parts(gates) do
      [
        boolean_part(gates),
        percentage_part(gates),
        count_part(gates, &Gate.actor?/1, "actor"),
        count_part(gates, &Gate.group?/1, "group")
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
