defmodule Mix.Tasks.Compile.ProjectionUiHost do
  @moduledoc """
  Compiler task that builds the Slint UI host binary and copies it to `priv/ui_host/`.

  Build mode selection:

    * `:release` — `MIX_ENV=prod`. Adds `--release`.
    * `:live_preview` — `MIX_ENV=dev` unless `PROJECTION_LIVE_PREVIEW=0`. Adds
      `--features live-preview`, sets `SLINT_LIVE_PREVIEW=1` for the cargo
      invocation, and builds into an isolated `target/live-preview/` dir so it
      does not clobber plain debug artifacts. Enables Slint's in-process
      `.slint` file watcher — UI edits reload without re-running cargo.
    * `:debug` — everything else (`:test`, or `:dev` with opt-out).

  Setting `PROJECTION_LIVE_PREVIEW=1` with `MIX_ENV=prod` is a hard error so
  the dev-only feature cannot leak into release builds.

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
    port_opts =
      [:binary, :exit_status, :stderr_to_stdout, args: build_args(manifest)] ++
        build_env()

    port = Port.open({:spawn_executable, cargo_path()}, port_opts)

    stream_port_output(port)
  end

  defp build_args(manifest) do
    base = ["build", "--color=always", "--manifest-path", manifest]

    case build_mode() do
      :release ->
        base ++ ["--release"]

      :live_preview ->
        base ++
          ["--features", "slint/live-preview", "--target-dir", live_preview_target_dir()]

      :debug ->
        base
    end
  end

  defp build_env do
    case build_mode() do
      :live_preview -> [env: [{~c"SLINT_LIVE_PREVIEW", ~c"1"}]]
      _ -> []
    end
  end

  @doc false
  def build_mode do
    case {Mix.env(), System.get_env("PROJECTION_LIVE_PREVIEW")} do
      {:prod, "1"} ->
        Mix.raise("PROJECTION_LIVE_PREVIEW=1 cannot be combined with MIX_ENV=prod")

      {:prod, _} ->
        :release

      {:dev, "0"} ->
        :debug

      {:dev, _} ->
        :live_preview

      _ ->
        :debug
    end
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
    current = Atom.to_string(build_mode())

    case {File.stat(destination), File.stat(manifest_path()), read_manifest_mode()} do
      {{:ok, _dest}, {:ok, manifest_stat}, ^current} ->
        latest_source_mtime() > manifest_stat.mtime

      _ ->
        true
    end
  end

  defp read_manifest_mode do
    case File.read(manifest_path()) do
      {:ok, content} ->
        case String.split(content, "\n", parts: 2) do
          [_ts, mode] -> String.trim(mode)
          _ -> nil
        end

      _ ->
        nil
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

    {target_dir, profile} =
      case build_mode() do
        :release -> {default_target_dir(), "release"}
        :debug -> {default_target_dir(), "debug"}
        :live_preview -> {live_preview_target_dir(), "debug"}
      end

    Path.join([target_dir, profile, "ui_host" <> suffix])
  end

  defp default_target_dir do
    Path.expand(Path.join(["slint", "ui_host", "target"]))
  end

  defp live_preview_target_dir do
    Path.expand(Path.join(["slint", "ui_host", "target", "live-preview"]))
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
    File.write!(path, "#{System.system_time(:second)}\n#{build_mode()}")
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
