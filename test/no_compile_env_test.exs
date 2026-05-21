defmodule NoCompileEnvTest do
  @moduledoc """
  Bandera's whole reason for existing is to avoid compile-time configuration
  (fun_with_flags#122). This test fails if an `Application.compile_env` call is
  ever introduced into the library source. (A doc/comment mention using the
  `Application.compile_env/3` arity form is allowed and does not match.)
  """
  use ExUnit.Case, async: true

  test "lib/ contains no Application.compile_env call" do
    offenders =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(fn path -> File.read!(path) =~ ~r/Application\.compile_env[!\s(]/ end)

    assert offenders == [],
           "Application.compile_env must not be used in Bandera. Offending files: #{inspect(offenders)}"
  end
end
