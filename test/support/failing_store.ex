defmodule Bandera.FailingStore do
  @moduledoc """
  Test stub store: every callback returns `{:error, :boom}`.

  Used to verify that the public `Bandera` API propagates store errors from
  writes and treats lookup failures as "not enabled" (logging a warning).
  """
  @behaviour Bandera.Store

  @error {:error, :boom}

  @impl true
  def lookup(_flag_name), do: @error

  @impl true
  def put(_flag_name, _gate), do: @error

  @impl true
  def delete(_flag_name, _gate), do: @error

  @impl true
  def delete(_flag_name), do: @error

  @impl true
  def all_flags, do: @error

  @impl true
  def all_flag_names, do: @error
end
