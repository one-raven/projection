defmodule Mix.Tasks.Compile.ProjectionUiHost do
  @moduledoc """
  Compiler task that builds the Slint UI host binary and copies it to `priv/ui_host/`.

  Uses `--release` in `:prod` Mix env, debug profile otherwise.
  Streams cargo output in real time with color support.
  """

  use Mix.Task.Compiler

  @recursive true

  @manifest_name ".compile.projection_ui_host"

  @source_dirs [
    "slint/ui_host/src",
    "slint/ui_host_runtime/src",
    "lib/projection/ui"
  ]

  @source_files [
    "slint/ui_host/Cargo.toml",
    "slint/ui_host/build.rs",
    "slint/ui_host_runtime/Cargo.toml"
  ]

  @impl true
  def manifests, do: [manifest_path()]

  @impl true
  def run(_args) do
    manifest = Path.expand("slint/ui_host/Cargo.toml")

    unless File.regular?(manifest) do
      {:ok, []}
    else
      destination = destination_path()

      if needs_rebuild?(destination) do
        case build_ui_host(manifest) do
          :ok ->
            copy_ui_host_binary!(destination)
            write_manifest()
            {:ok, []}

          {:error, status} ->
            {:error,
             [
               diagnostic(
                 "cargo build failed (exit #{status}) — see output above",
                 "slint/ui_host/Cargo.toml"
               )
             ]}
        end
      else
        {:noop, []}
      end
    end
  end

  @impl true
  def clean do
    File.rm(manifest_path())
    File.rm(destination_path())
    :ok
  end

  defp build_ui_host(manifest) do
    build_args =
      ["build", "--color=always", "--manifest-path", manifest] ++
        if(Mix.env() == :prod, do: ["--release"], else: [])

    port =
      Port.open({:spawn_executable, cargo_path()}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: build_args
      ])

    stream_port_output(port)
  end

  defp stream_port_output(port) do
    receive do
      {^port, {:data, data}} ->
        :io.put_chars(:standard_error, data)
        stream_port_output(port)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, status}} ->
        {:error, status}
    end
  end

  defp cargo_path do
    System.find_executable("cargo") ||
      Mix.raise("cargo not found in PATH — install Rust: https://rustup.rs")
  end

  defp needs_rebuild?(destination) do
    case {File.stat(destination), File.stat(manifest_path())} do
      {{:ok, _dest}, {:ok, manifest_stat}} ->
        latest_source_mtime() > manifest_stat.mtime

      _ ->
        true
    end
  end

  defp latest_source_mtime do
    source_files =
      Enum.flat_map(@source_dirs, fn dir ->
        dir
        |> Path.expand()
        |> Path.join("**/*")
        |> Path.wildcard()
      end) ++ Enum.map(@source_files, &Path.expand/1)

    source_files
    |> Enum.map(fn path ->
      case File.stat(path) do
        {:ok, %{mtime: mtime}} -> mtime
        _ -> {{2099, 1, 1}, {0, 0, 0}}
      end
    end)
    |> Enum.max(fn -> {{2099, 1, 1}, {0, 0, 0}} end)
  end

  defp copy_ui_host_binary!(destination) do
    source = source_binary_path()

    unless File.regular?(source) do
      Mix.raise("ui_host executable not found at #{source}")
    end

    File.mkdir_p!(Path.dirname(destination))
    File.cp!(source, destination)
  end

  defp source_binary_path do
    suffix = if match?({:win32, _}, :os.type()), do: ".exe", else: ""
    profile = if Mix.env() == :prod, do: "release", else: "debug"
    Path.expand(Path.join(["slint", "ui_host", "target", profile, "ui_host" <> suffix]))
  end

  defp destination_path do
    suffix = if match?({:win32, _}, :os.type()), do: ".exe", else: ""
    Path.expand(Path.join(["priv", "ui_host", "ui_host" <> suffix]))
  end

  defp manifest_path do
    Path.join(Mix.Project.manifest_path(), @manifest_name)
  end

  defp write_manifest do
    path = manifest_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#{System.system_time(:second)}")
  end

  defp diagnostic(message, file) do
    %Mix.Task.Compiler.Diagnostic{
      file: Path.expand(file),
      position: nil,
      message: message,
      severity: :error,
      compiler_name: "projection_ui_host"
    }
  end
end
