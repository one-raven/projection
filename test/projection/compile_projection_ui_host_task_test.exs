defmodule Projection.CompileProjectionUiHostTaskTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Compile.ProjectionUiHost

  @env_var "PROJECTION_LIVE_PREVIEW"

  setup do
    original_env = Mix.env()
    original_var = System.get_env(@env_var)

    on_exit(fn ->
      Mix.env(original_env)

      case original_var do
        nil -> System.delete_env(@env_var)
        value -> System.put_env(@env_var, value)
      end
    end)

    :ok
  end

  describe "build_mode/0" do
    test ":dev auto-enables live-preview" do
      Mix.env(:dev)
      System.delete_env(@env_var)
      assert ProjectionUiHost.build_mode() == :live_preview
    end

    test ":dev with PROJECTION_LIVE_PREVIEW=0 falls back to :debug" do
      Mix.env(:dev)
      System.put_env(@env_var, "0")
      assert ProjectionUiHost.build_mode() == :debug
    end

    test ":dev with PROJECTION_LIVE_PREVIEW=1 stays :live_preview" do
      Mix.env(:dev)
      System.put_env(@env_var, "1")
      assert ProjectionUiHost.build_mode() == :live_preview
    end

    test ":test is always :debug, regardless of env var" do
      Mix.env(:test)

      for value <- [nil, "0", "1"] do
        case value do
          nil -> System.delete_env(@env_var)
          v -> System.put_env(@env_var, v)
        end

        assert ProjectionUiHost.build_mode() == :debug
      end
    end

    test ":prod is :release without the env var" do
      Mix.env(:prod)
      System.delete_env(@env_var)
      assert ProjectionUiHost.build_mode() == :release
    end

    test ":prod with PROJECTION_LIVE_PREVIEW=0 is still :release" do
      Mix.env(:prod)
      System.put_env(@env_var, "0")
      assert ProjectionUiHost.build_mode() == :release
    end

    test ":prod with PROJECTION_LIVE_PREVIEW=1 raises" do
      Mix.env(:prod)
      System.put_env(@env_var, "1")

      assert_raise Mix.Error,
                   ~r/PROJECTION_LIVE_PREVIEW=1 cannot be combined with MIX_ENV=prod/,
                   fn ->
                     ProjectionUiHost.build_mode()
                   end
    end
  end
end
