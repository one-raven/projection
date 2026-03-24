defmodule Projection.CodegenTestHelpers do
  @moduledoc false

  import ExUnit.CaptureIO

  @env_keys [:router_module, :screen_modules]

  @doc """
  Saves the current Application env for `:projection` codegen keys,
  applies the given overrides, reenables the codegen task, and returns
  a cleanup function suitable for `on_exit/1`.

  ## Options

    * `:router_module` — value to set, or `:delete` to remove
    * `:screen_modules` — value to set, or `:delete` to remove
    * `:restore_codegen` — if `true` (default), re-runs codegen with
      `PROJECTION_ALLOW_EMPTY=1` during cleanup to reset generated files

  ## Example

      cleanup = setup_codegen_env(router_module: :delete, screen_modules: [MyScreen])
      on_exit(cleanup)

  """
  def setup_codegen_env(overrides \\ []) do
    restore_codegen = Keyword.get(overrides, :restore_codegen, true)

    originals =
      Map.new(@env_keys, fn key ->
        {key, Application.get_env(:projection, key)}
      end)

    Enum.each(@env_keys, fn key ->
      case Keyword.fetch(overrides, key) do
        {:ok, :delete} -> Application.delete_env(:projection, key)
        {:ok, value} -> Application.put_env(:projection, key, value)
        :error -> :ok
      end
    end)

    Mix.Task.reenable("projection.codegen")

    fn ->
      Enum.each(@env_keys, fn key ->
        case Map.fetch!(originals, key) do
          nil -> Application.delete_env(:projection, key)
          value -> Application.put_env(:projection, key, value)
        end
      end)

      if restore_codegen do
        run_codegen_with_allow_empty()
      end
    end
  end

  defp run_codegen_with_allow_empty do
    Mix.Task.reenable("projection.codegen")
    previous = System.get_env("PROJECTION_ALLOW_EMPTY")
    System.put_env("PROJECTION_ALLOW_EMPTY", "1")

    try do
      capture_io(fn ->
        Mix.Tasks.Projection.Codegen.run([])
      end)
    after
      if is_nil(previous) do
        System.delete_env("PROJECTION_ALLOW_EMPTY")
      else
        System.put_env("PROJECTION_ALLOW_EMPTY", previous)
      end
    end
  end
end
