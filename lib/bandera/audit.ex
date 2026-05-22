defmodule Bandera.Audit do
  @moduledoc """
  Opt-in audit hook. Turns Bandera's existing write telemetry
  (`[:bandera, :enable|:disable|:clear]` span `:stop` events) into structured
  `Bandera.Audit.Event` records and forwards them to a callback you provide.

      Bandera.Audit.attach(:my_audit, fn event ->
        MyApp.AuditLog.insert!(event)
      end)
  """

  defmodule Event do
    @moduledoc "A single flag-change audit record."
    @enforce_keys [:action, :flag_name, :at]
    defstruct [:action, :flag_name, :options, :result, :actor, :at]

    @type t :: %__MODULE__{
            action: :enable | :disable | :clear,
            flag_name: atom,
            options: keyword,
            result: term,
            actor: term,
            at: DateTime.t()
          }
  end

  @actions [:enable, :disable, :clear]

  @doc false
  @spec from_telemetry([atom], map) :: Event.t()
  def from_telemetry([:bandera, action, :stop], metadata) when action in @actions do
    options = Map.get(metadata, :options, [])

    %Event{
      action: action,
      flag_name: Map.get(metadata, :flag_name),
      options: options,
      result: Map.get(metadata, :result),
      actor: Keyword.get(options, :by),
      at: DateTime.utc_now()
    }
  end

  @stop_events for action <- @actions, do: [:bandera, action, :stop]

  @doc """
  Attach a handler that invokes `callback` with a `Bandera.Audit.Event` for every
  `enable`/`disable`/`clear`. `handler_id` is any term unique to this handler.
  """
  @spec attach(term, (Event.t() -> any)) :: :ok | {:error, :already_exists}
  def attach(handler_id, callback) when is_function(callback, 1) do
    :telemetry.attach_many(
      handler_id,
      @stop_events,
      fn event_name, _measurements, metadata, cb -> cb.(from_telemetry(event_name, metadata)) end,
      callback
    )
  end

  @doc "Detach a handler attached with `attach/2`."
  @spec detach(term) :: :ok | {:error, :not_found}
  def detach(handler_id), do: :telemetry.detach(handler_id)
end
