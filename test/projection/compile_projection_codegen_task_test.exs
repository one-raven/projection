defmodule Projection.CompileProjectionCodegenTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @required_ui_shell_files ~w(app_shell.slint error.slint screen.slint ui.slint)

  defmodule AliasRouteRouter do
    use Projection.Router.DSL

    alias Projection.TestScreens.Devices

    screen_session :main do
      screen("/monitoring", Devices, :index, as: :monitoring)
    end
  end

  setup do
    restore_ui_shell_files = ensure_required_ui_shell_files!()
    on_exit(restore_ui_shell_files)
    :ok
  end

  test "compile.projection_codegen completes without recursive loadpath failures" do
    original_router_module = Application.get_env(:projection, :router_module)
    original_screen_modules = Application.get_env(:projection, :screen_modules)

    Application.delete_env(:projection, :router_module)
    Application.put_env(:projection, :screen_modules, [Projection.TestScreens.Clock])

    on_exit(fn ->
      if is_nil(original_router_module) do
        Application.delete_env(:projection, :router_module)
      else
        Application.put_env(:projection, :router_module, original_router_module)
      end

      if is_nil(original_screen_modules) do
        Application.delete_env(:projection, :screen_modules)
      else
        Application.put_env(:projection, :screen_modules, original_screen_modules)
      end
    end)

    Mix.Task.reenable("projection.codegen")

    capture_io(fn ->
      assert {:ok, []} = Mix.Tasks.Compile.ProjectionCodegen.run([])
    end)
  end

  test "projection.codegen raises when a screen declares unsupported :map fields" do
    module_name = :"MapFieldScreen#{System.unique_integer([:positive])}"
    module = Module.concat([Projection, module_name])

    source = """
    defmodule #{inspect(module)} do
      use ProjectionUI, :screen

      schema do
        field :data, :map, default: %{}
      end
    end
    """

    Code.compile_string(source)

    original_router_module = Application.get_env(:projection, :router_module)
    original_screen_modules = Application.get_env(:projection, :screen_modules)

    Application.delete_env(:projection, :router_module)
    Application.put_env(:projection, :screen_modules, [module])

    on_exit(fn ->
      if is_nil(original_router_module) do
        Application.delete_env(:projection, :router_module)
      else
        Application.put_env(:projection, :router_module, original_router_module)
      end

      if is_nil(original_screen_modules) do
        Application.delete_env(:projection, :screen_modules)
      else
        Application.put_env(:projection, :screen_modules, original_screen_modules)
      end
    end)

    Mix.Task.reenable("projection.codegen")

    assert_raise ArgumentError, ~r/does not support.*:map/, fn ->
      capture_io(fn ->
        Mix.Tasks.Projection.Codegen.run([])
      end)
    end
  end

  test "projection.codegen emits typed list bindings from schema items option" do
    module_name = :"TypedListScreen#{System.unique_integer([:positive])}"
    module = Module.concat([Projection, module_name])

    source = """
    defmodule #{inspect(module)} do
      use ProjectionUI, :screen

      schema do
        field :tiles, :list, items: :integer, default: [1, 2, 3]
        field :ratios, :list, items: :float, default: [1.0, 0.5]
        field :flags, :list, items: :bool, default: [true, false]
        field :labels, :list, default: ["a", "b"]
      end

      @impl true
      def render(assigns), do: assigns
    end
    """

    Code.compile_string(source)

    original_router_module = Application.get_env(:projection, :router_module)
    original_screen_modules = Application.get_env(:projection, :screen_modules)
    Application.delete_env(:projection, :router_module)
    Application.put_env(:projection, :screen_modules, [module])

    on_exit(fn ->
      if original_router_module do
        Application.put_env(:projection, :router_module, original_router_module)
      else
        Application.delete_env(:projection, :router_module)
      end

      if is_nil(original_screen_modules) do
        Application.delete_env(:projection, :screen_modules)
      else
        Application.put_env(:projection, :screen_modules, original_screen_modules)
      end

      Mix.Task.reenable("projection.codegen")

      capture_io(fn ->
        previous_allow_empty = System.get_env("PROJECTION_ALLOW_EMPTY")
        System.put_env("PROJECTION_ALLOW_EMPTY", "1")

        try do
          Mix.Tasks.Projection.Codegen.run([])
        after
          if is_nil(previous_allow_empty) do
            System.delete_env("PROJECTION_ALLOW_EMPTY")
          else
            System.put_env("PROJECTION_ALLOW_EMPTY", previous_allow_empty)
          end
        end
      end)
    end)

    Mix.Task.reenable("projection.codegen")

    capture_io(fn ->
      Mix.Tasks.Projection.Codegen.run([])
    end)

    screen_name =
      module
      |> Module.split()
      |> List.last()
      |> Macro.underscore()

    state_slint = File.read!("slint/ui_host/src/generated/#{screen_name}_state.slint")
    assert state_slint =~ "in property <[int]> tiles: [1, 2, 3];"
    assert state_slint =~ ~r/in property <\[float\]> ratios: \[(1|1\.0), 0\.5\];/
    assert state_slint =~ "in property <[bool]> flags: [true, false];"
    assert state_slint =~ "in property <[string]> labels: [\"a\", \"b\"];"

    screen_rs = File.read!("slint/ui_host/src/generated/#{screen_name}.rs")

    assert screen_rs =~
             "fn parse_integer_list(value: &Value, path: &str) -> Result<Vec<i64>, String>"

    assert screen_rs =~
             "fn parse_float_list(value: &Value, path: &str) -> Result<Vec<f64>, String>"

    assert screen_rs =~
             "fn parse_bool_list(value: &Value, path: &str) -> Result<Vec<bool>, String>"

    assert screen_rs =~ "collect::<Result<Vec<i32>, String>>()?"
    assert screen_rs =~ "let model = slint::VecModel::from(parsed);"
  end

  test "projection.codegen emits typed id_table column bindings" do
    module_name = :"TypedIdTableScreen#{System.unique_integer([:positive])}"
    module = Module.concat([Projection, module_name])

    source = """
    defmodule #{inspect(module)} do
      use ProjectionUI, :screen

      schema do
        field(:devices, :id_table,
          columns: [name: :string, pos: :integer, load: :float, online: :bool],
          default: %{
            order: ["dev-1", "dev-2"],
            by_id: %{
              "dev-1" => %{name: "A", pos: 1, load: 0.5, online: true},
              "dev-2" => %{name: "B", pos: 2, load: 1.0, online: false}
            }
          }
        )
      end

      @impl true
      def render(assigns), do: assigns
    end
    """

    Code.compile_string(source)

    original_router_module = Application.get_env(:projection, :router_module)
    original_screen_modules = Application.get_env(:projection, :screen_modules)
    Application.delete_env(:projection, :router_module)
    Application.put_env(:projection, :screen_modules, [module])

    on_exit(fn ->
      if original_router_module do
        Application.put_env(:projection, :router_module, original_router_module)
      else
        Application.delete_env(:projection, :router_module)
      end

      if is_nil(original_screen_modules) do
        Application.delete_env(:projection, :screen_modules)
      else
        Application.put_env(:projection, :screen_modules, original_screen_modules)
      end

      Mix.Task.reenable("projection.codegen")

      capture_io(fn ->
        previous_allow_empty = System.get_env("PROJECTION_ALLOW_EMPTY")
        System.put_env("PROJECTION_ALLOW_EMPTY", "1")

        try do
          Mix.Tasks.Projection.Codegen.run([])
        after
          if is_nil(previous_allow_empty) do
            System.delete_env("PROJECTION_ALLOW_EMPTY")
          else
            System.put_env("PROJECTION_ALLOW_EMPTY", previous_allow_empty)
          end
        end
      end)
    end)

    Mix.Task.reenable("projection.codegen")

    capture_io(fn ->
      Mix.Tasks.Projection.Codegen.run([])
    end)

    screen_name =
      module
      |> Module.split()
      |> List.last()
      |> Macro.underscore()

    state_slint = File.read!("slint/ui_host/src/generated/#{screen_name}_state.slint")
    assert state_slint =~ "in property <[string]> devices_ids: [\"dev-1\", \"dev-2\"];"
    assert state_slint =~ "in property <[string]> devices_name: [\"A\", \"B\"];"
    assert state_slint =~ "in property <[int]> devices_pos: [1, 2];"
    assert state_slint =~ ~r/in property <\[float\]> devices_load: \[0\.5, (1|1\.0)\];/
    assert state_slint =~ "in property <[bool]> devices_online: [true, false];"

    screen_rs = File.read!("slint/ui_host/src/generated/#{screen_name}.rs")
    assert screen_rs =~ "columns: std::collections::BTreeMap<String, Vec<Value>>"
    assert screen_rs =~ "parse_integer_list(&Value::Array(raw_values)"
    assert screen_rs =~ "parse_float_list(&Value::Array(raw_values)"
    assert screen_rs =~ "parse_bool_list(&Value::Array(raw_values)"
  end

  test "projection.codegen maps aliased route names to the referenced screen id" do
    original_router_module = Application.get_env(:projection, :router_module)
    original_screen_modules = Application.get_env(:projection, :screen_modules)
    Application.put_env(:projection, :router_module, AliasRouteRouter)
    Application.delete_env(:projection, :screen_modules)

    on_exit(fn ->
      if original_router_module do
        Application.put_env(:projection, :router_module, original_router_module)
      else
        Application.delete_env(:projection, :router_module)
      end

      if is_nil(original_screen_modules) do
        Application.delete_env(:projection, :screen_modules)
      else
        Application.put_env(:projection, :screen_modules, original_screen_modules)
      end

      Mix.Task.reenable("projection.codegen")

      capture_io(fn ->
        previous_allow_empty = System.get_env("PROJECTION_ALLOW_EMPTY")
        System.put_env("PROJECTION_ALLOW_EMPTY", "1")

        try do
          Mix.Tasks.Projection.Codegen.run([])
        after
          if is_nil(previous_allow_empty) do
            System.delete_env("PROJECTION_ALLOW_EMPTY")
          else
            System.put_env("PROJECTION_ALLOW_EMPTY", previous_allow_empty)
          end
        end
      end)
    end)

    Mix.Task.reenable("projection.codegen")

    capture_io(fn ->
      Mix.Tasks.Projection.Codegen.run([])
    end)

    mod_rs = File.read!("slint/ui_host/src/generated/mod.rs")

    assert mod_rs =~ "Some(\"monitoring\") => ScreenId::Devices"
    refute mod_rs =~ "Some(\"devices\") => ScreenId::Devices"
  end

  defp ensure_required_ui_shell_files! do
    ui_root = Path.join(File.cwd!(), configured_ui_root())
    File.mkdir_p!(ui_root)

    snapshots =
      Map.new(@required_ui_shell_files, fn file ->
        path = Path.join(ui_root, file)

        snapshot =
          case File.read(path) do
            {:ok, content} -> {:existing, content}
            {:error, _reason} -> :missing
          end

        {file, snapshot}
      end)

    Enum.each(@required_ui_shell_files, fn file ->
      path = Path.join(ui_root, file)

      if Map.fetch!(snapshots, file) == :missing do
        File.write!(path, "// required by projection.codegen tests\n")
      end
    end)

    fn ->
      Enum.each(@required_ui_shell_files, fn file ->
        path = Path.join(ui_root, file)

        case Map.fetch!(snapshots, file) do
          {:existing, content} ->
            File.write!(path, content)

          :missing ->
            File.rm(path)
        end
      end)

      case File.ls(ui_root) do
        {:ok, []} -> File.rmdir(ui_root)
        _ -> :ok
      end
    end
  end

  defp configured_ui_root do
    case Application.get_env(:projection, :ui_root) do
      path when is_binary(path) and path != "" ->
        path

      _ ->
        app =
          case Mix.Project.config()[:app] do
            value when is_atom(value) -> Atom.to_string(value)
            _ -> "projection"
          end

        Path.join(["lib", app, "ui"])
    end
  end
end
