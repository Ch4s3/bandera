if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Bandera.Dashboard.Components do
    @moduledoc "Function components for the Bandera dashboard."
    use Phoenix.Component

    alias Bandera.Gate

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
