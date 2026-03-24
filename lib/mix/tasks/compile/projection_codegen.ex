defmodule Mix.Tasks.Compile.ProjectionCodegen do
  @moduledoc """
  Compiler task that runs `mix projection.codegen` as part of `mix compile`.
  """

  use Mix.Task.Compiler

  @recursive true

  @impl true
  def run(_args) do
    Mix.Task.run("projection.codegen")
    {:ok, []}
  rescue
    error ->
      stacktrace = __STACKTRACE__
      formatted = Exception.format(:error, error, stacktrace)
      Mix.shell().error("projection_codegen failed:\n#{formatted}")
      Mix.Task.reenable("projection.codegen")
      {:error, ["projection_codegen failed: #{Exception.message(error)}"]}
  end
end
