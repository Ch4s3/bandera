defmodule Bandera.ApplicationTest do
  use ExUnit.Case, async: false

  alias Bandera.Store.Cache
  alias Bandera.Store.Persistent.Memory

  setup do
    start_supervised!(Memory)
    start_supervised!(Cache)
    Application.put_env(:bandera, :persistence, adapter: Memory)
    Application.put_env(:bandera, :store, Bandera.Store.TwoLevel)
    Application.put_env(:bandera, :cache, enabled: true, ttl: 900)
    Bandera.reload_config()

    on_exit(fn ->
      Application.delete_env(:bandera, :persistence)
      Application.delete_env(:bandera, :store)
      Application.delete_env(:bandera, :cache)
      Bandera.reload_config()
    end)

    :ok
  end

  test "the application seeded the Config snapshot at boot" do
    assert is_map(:persistent_term.get({Bandera.Config, :snapshot}, nil))
  end

  test "end-to-end flag toggle works through the full stack" do
    refute Bandera.enabled?(:boot_flag)
    assert {:ok, true} = Bandera.enable(:boot_flag)
    assert Bandera.enabled?(:boot_flag)
  end
end
