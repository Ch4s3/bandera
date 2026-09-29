defmodule Bandera.Telemetry do
  @moduledoc """
  Telemetry events for Bandera.

  All events are prefixed with `:bandera`. The hot read path uses lightweight
  point-in-time events; writes and introspection use span events.

  Every event's metadata carries `instance` — the name of the Bandera instance
  the call ran against (`Bandera` for the default instance, or whatever name a
  `use Bandera` module or `{Bandera, name: ...}` instance was started with).
  Running one instance, this is always `Bandera`; running several, it lets one
  handler distinguish which instance a call belongs to. See the
  [Running Multiple Instances guide](multiple_instances_guide.html).

  ## Point-in-time events (measurement: `%{system_time}`)

  * `[:bandera, :enabled?]` — a flag was checked. Metadata: `%{flag_name, options, result, instance}`.
  * `[:bandera, :variant]` — a variant was resolved. Metadata: `%{flag_name, options, result, instance}`.
  * `[:bandera, :persistence, :get]` — a flag was read from the persistent
    adapter. Emitted ONLY on a cache miss (a cache hit does not read the
    adapter). Metadata: `%{flag_name, instance}`.

  ## Span events (`…:start` / `…:stop` with `:duration` / `…:exception`)

  Emitted via `:telemetry.span/3`.

  `:stop`/`:exception` events carry the start metadata (e.g. `flag_name`,
  `options`, `instance`) merged with any extra stop fields (e.g. `result`).

  * `[:bandera, :enable]`, `[:bandera, :disable]`, `[:bandera, :clear]` — public
    API writes. Start metadata `%{flag_name, options, instance}`; stop metadata `%{result}`.
  * `[:bandera, :put_variants]` — multivariate gate write. Start metadata
    `%{flag_name, weights, instance}`; stop metadata `%{result}`.
  * `[:bandera, :persistence, :put]`, `[:bandera, :persistence, :delete]` — store
    writes. Start metadata `%{flag_name, gate, instance}` (gate where applicable).
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
