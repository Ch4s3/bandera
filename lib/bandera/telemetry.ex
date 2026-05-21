defmodule Bandera.Telemetry do
  @moduledoc """
  Telemetry events for Bandera.

  All events are prefixed with `:bandera`. The hot read path uses lightweight
  point-in-time events; writes and introspection use span events.

  ## Point-in-time events (measurement: `%{system_time}`)

  * `[:bandera, :enabled?]` — a flag was checked. Metadata: `%{flag_name, options, result}`.
  * `[:bandera, :persistence, :get]` — a flag was read from the persistent
    adapter. Emitted ONLY on a cache miss (a cache hit does not read the
    adapter). Metadata: `%{flag_name}`.

  ## Span events (`…:start` / `…:stop` with `:duration` / `…:exception`)

  Emitted via `:telemetry.span/3`.

  `:stop`/`:exception` events carry the start metadata (e.g. `flag_name`,
  `options`) merged with any extra stop fields (e.g. `result`).

  * `[:bandera, :enable]`, `[:bandera, :disable]`, `[:bandera, :clear]` — public
    API writes. Start metadata `%{flag_name, options}`; stop metadata `%{result}`.
  * `[:bandera, :persistence, :put]`, `[:bandera, :persistence, :delete]` — store
    writes. Start metadata `%{flag_name, gate}` (gate where applicable).
  * `[:bandera, :persistence, :all_flags]`, `[:bandera, :persistence, :all_flag_names]`.
  """

  @prefix :bandera

  @doc """
  Run `fun` inside a `:telemetry` span under `[:bandera | prefix]`. `fun` returns
  `{result, extra_stop_metadata}` and the function's `result` is returned.

  The `:stop` event carries the start `metadata` merged with `extra_stop_metadata`
  (stop fields win on key conflict). The `:exception` event carries the start
  `metadata` with `kind`, `reason`, and `stacktrace` added by `:telemetry`
  automatically (the function does not run to completion on a raise).
  """
  @spec span([atom], map(), (-> {result, map()})) :: result when result: var
  def span(prefix, metadata, fun)
      when is_list(prefix) and is_map(metadata) and is_function(fun, 0) do
    :telemetry.span([@prefix | prefix], metadata, fn ->
      {result, stop_metadata} = fun.()
      {result, Map.merge(metadata, stop_metadata)}
    end)
  end

  @doc "Emit a point-in-time `:telemetry` event under `[:bandera | prefix]` with a `system_time` measurement."
  @spec event([atom], map()) :: :ok
  def event(prefix, metadata) when is_list(prefix) and is_map(metadata) do
    :telemetry.execute([@prefix | prefix], %{system_time: :erlang.system_time()}, metadata)
  end
end
