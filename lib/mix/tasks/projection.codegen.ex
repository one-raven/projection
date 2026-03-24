defmodule Mix.Tasks.Projection.Codegen do
  use Mix.Task

  @shortdoc "Generates typed Rust screen bindings from ProjectionUI schema metadata"

  @moduledoc """
  Generates Rust binding glue under `slint/ui_host/src/generated/` from
  `__projection_schema__/0` metadata exported by screen modules.
  """

  @supported_schema_types [:string, :bool, :integer, :float, :map, :list, :id_table, :component]
  @supported_codegen_types [:string, :bool, :integer, :float, :list, :id_table, :component]
  @required_ui_shell_files ~w(app_shell.slint error.slint screen.slint ui.slint)

  @impl Mix.Task
  def run(_args) do
    ensure_apps_loaded!(configured_otp_apps())

    router_module = discover_router_module()
    routes = discover_routes(router_module)
    ui_root = configured_ui_root()
    ui_root_from_generated = ui_root_from_generated(ui_root)
    ui_root_from_ui_host = ui_root_from_ui_host(ui_root)

    specs =
      discover_screen_modules(routes)
      |> Enum.map(&build_screen_spec/1)
      |> Enum.sort_by(& &1.module_name)

    Enum.each(specs, fn spec ->
      if function_exported?(spec.module, :render, 1) do
        ProjectionUI.Schema.validate_render!(spec.module)
      end
    end)

    app_module = discover_app_module()
    app_spec = if app_module, do: build_app_state_spec(app_module), else: nil

    ensure_codegen_targets!(specs, routes)
    ensure_required_ui_shell_files!(specs, routes, ui_root)

    generated_dir = Path.join(File.cwd!(), "slint/ui_host/src/generated")
    File.mkdir_p!(generated_dir)

    screen_results =
      specs
      |> Task.async_stream(
        fn spec ->
          rs =
            write_file_if_changed(
              Path.join(generated_dir, "#{spec.file_name}.rs"),
              render_screen_module(spec)
            )

          slint =
            write_file_if_changed(
              Path.join(generated_dir, spec.state_file),
              render_screen_state_slint(spec)
            )

          {rs, slint}
        end,
        ordered: false,
        timeout: codegen_task_timeout(),
        max_concurrency: max_concurrency()
      )
      |> Enum.map(&unwrap_task_result!/1)

    {screen_rs_results, screen_slint_results} = Enum.unzip(screen_results)

    app_state_results =
      if app_spec do
        [
          write_file_if_changed(
            Path.join(generated_dir, "app_state.rs"),
            render_app_state_module(app_spec)
          ),
          write_file_if_changed(
            Path.join(generated_dir, "app_state.slint"),
            render_app_state_slint(app_spec)
          )
        ]
      else
        []
      end

    mod_result =
      write_file_if_changed(
        Path.join(generated_dir, "mod.rs"),
        render_generated_mod(specs, routes, app_spec)
      )

    routes_result =
      write_file_if_changed(Path.join(generated_dir, "routes.slint"), render_routes_slint(routes))

    screen_host_result =
      write_file_if_changed(
        Path.join(generated_dir, "screen_host.slint"),
        render_screen_host_slint(specs, routes, ui_root_from_generated)
      )

    app_result =
      write_file_if_changed(
        Path.join(generated_dir, "app.slint"),
        render_generated_app_slint(specs, routes, ui_root_from_generated, app_spec)
      )

    error_state_result =
      write_file_if_changed(
        Path.join(generated_dir, "error_state.slint"),
        render_error_state_slint()
      )

    build_rs_result =
      write_file_if_changed(
        Path.join(File.cwd!(), "slint/ui_host/build.rs"),
        render_build_rs(specs, ui_root_from_ui_host, app_spec)
      )

    removed_count = prune_stale_generated_files(generated_dir, specs, app_spec)

    written_count =
      Enum.count(
        screen_rs_results ++
          screen_slint_results ++
          app_state_results ++
          [
            mod_result,
            routes_result,
            screen_host_result,
            app_result,
            error_state_result,
            build_rs_result
          ],
        fn
          :written -> true
          _ -> false
        end
      )

    Mix.shell().info(
      "projection.codegen generated #{length(specs)} screen module(s), #{length(routes)} route constant(s), wrote #{written_count} file(s), removed #{removed_count} stale file(s)"
    )
  end

  defp discover_router_module do
    Application.get_env(:projection, :router_module)
  end

  defp discover_routes(nil), do: []

  defp discover_routes(router_module) do
    if Code.ensure_loaded?(router_module) and function_exported?(router_module, :route_defs, 0) do
      route_defs = router_module.route_defs()

      route_names =
        if function_exported?(router_module, :route_names, 0) do
          router_module.route_names()
        else
          route_defs
          |> Map.keys()
          |> Enum.sort()
        end

      route_names
      |> Enum.map(fn route_name ->
        case route_defs do
          %{^route_name => route_def} -> normalize_route!(route_def)
          _ -> raise ArgumentError, "unknown route #{inspect(route_name)} in router metadata"
        end
      end)
    else
      []
    end
  end

  defp normalize_route!(%{
         name: name,
         path: path,
         route_key: route_key,
         screen_module: screen_module,
         screen_session: screen_session
       })
       when is_binary(name) and is_binary(path) and is_atom(route_key) and
              is_atom(screen_module) and is_atom(screen_session) do
    %{
      name: name,
      path: path,
      route_key: route_key,
      screen_module: screen_module,
      screen_session: screen_session
    }
  end

  defp normalize_route!(%{
         name: name,
         path: path,
         screen_module: screen_module,
         screen_session: screen_session
       })
       when is_binary(name) and is_binary(path) and is_atom(screen_module) and
              is_atom(screen_session) do
    %{
      name: name,
      path: path,
      route_key: String.to_atom(name),
      screen_module: screen_module,
      screen_session: screen_session
    }
  end

  defp normalize_route!(route) do
    raise ArgumentError, "invalid route metadata for codegen: #{inspect(route)}"
  end

  defp discover_screen_modules(routes) when is_list(routes) do
    route_modules =
      routes
      |> Enum.map(& &1.screen_module)
      |> Enum.filter(&is_atom/1)

    configured_modules = configured_screen_modules()

    marker_modules =
      configured_otp_apps()
      |> Enum.flat_map(fn app ->
        app
        |> Application.spec(:modules)
        |> List.wrap()
      end)
      |> Enum.filter(&Code.ensure_loaded?/1)
      |> Enum.filter(&function_exported?(&1, :__projection_screen__, 0))
      |> Enum.filter(&function_exported?(&1, :__projection_schema__, 0))

    (route_modules ++ configured_modules ++ marker_modules)
    |> Enum.uniq()
    |> Enum.filter(&Code.ensure_loaded?/1)
    |> Enum.filter(&function_exported?(&1, :__projection_schema__, 0))
    |> Enum.sort_by(&Atom.to_string/1)
  end

  defp discover_app_module do
    case Application.get_env(:projection, :app_module) do
      module when is_atom(module) and not is_nil(module) ->
        if Code.ensure_loaded?(module) and
             function_exported?(module, :__projection_app_state__, 0) and
             function_exported?(module, :__projection_schema__, 0) do
          module
        else
          Mix.raise("configured app_module #{inspect(module)} must use ProjectionUI, :app_state")
        end

      _ ->
        nil
    end
  end

  @supported_app_state_types [:string, :bool, :integer, :float, :list]

  defp build_app_state_spec(module) do
    metadata = module.__projection_schema__()

    fields =
      metadata
      |> Enum.map(&normalize_field!/1)
      |> Enum.sort_by(&Atom.to_string(&1.name))

    unsupported_app_fields =
      Enum.reject(fields, &(&1.type in @supported_app_state_types))

    if unsupported_app_fields != [] do
      descriptions =
        Enum.map_join(unsupported_app_fields, ", ", &"#{&1.name}: #{inspect(&1.type)}")

      Mix.raise(
        "projection.codegen does not support #{descriptions} in app_state module #{inspect(module)}. " <>
          "App state only supports direct scalar and list fields."
      )
    end

    codegen_fields =
      fields
      |> Enum.flat_map(&expand_codegen_field/1)

    %{
      module: module,
      module_name: Atom.to_string(module),
      global_name: "AppState",
      fields: codegen_fields
    }
  end

  defp ensure_codegen_targets!([], routes) when is_list(routes) do
    if allow_empty_codegen?() do
      :ok
    else
      route_hint =
        if routes == [] do
          "Set `config :projection, router_module: MyApp.Router` and/or " <>
            "`config :projection, screen_modules: [MyApp.Screens.Home]`."
        else
          "Verify all route screen modules export `__projection_screen__/0` and `__projection_schema__/0`."
        end

      Mix.raise(
        "projection.codegen discovered no screen modules. " <>
          route_hint <>
          " Set `PROJECTION_ALLOW_EMPTY=1` to bypass."
      )
    end
  end

  defp ensure_codegen_targets!(_specs, _routes), do: :ok

  defp ensure_required_ui_shell_files!(specs, routes, _ui_root)
       when specs == [] and routes == [] do
    :ok
  end

  defp ensure_required_ui_shell_files!(_specs, _routes, ui_root) do
    root = Path.join(File.cwd!(), ui_root)

    missing =
      @required_ui_shell_files
      |> Enum.reject(fn file ->
        File.regular?(Path.join(root, file))
      end)

    if missing != [] do
      Mix.raise("""
      projection.codegen requires app-owned Slint shell files under `#{ui_root}/`.

      Required:
      #{Enum.map_join(@required_ui_shell_files, "\n", &"  - #{&1}")}

      Missing:
      #{Enum.map_join(missing, "\n", &"  - #{&1}")}

      See the "Slint shell files" section in the README for starter templates.
      """)
    end
  end

  defp allow_empty_codegen? do
    System.get_env("PROJECTION_ALLOW_EMPTY") in ["1", "true", "TRUE", "yes", "YES"]
  end

  defp configured_ui_root do
    configured =
      case Application.get_env(:projection, :ui_root) do
        path when is_binary(path) ->
          path
          |> String.trim()
          |> String.trim_leading("./")
          |> String.trim_trailing("/")

        nil ->
          default_ui_root()

        other ->
          Mix.raise("config :projection, :ui_root must be a string, got: #{inspect(other)}")
      end

    cond do
      configured == "" ->
        default_ui_root()

      Path.type(configured) != :relative ->
        Mix.raise(
          "config :projection, :ui_root must be a relative path, got: #{inspect(configured)}"
        )

      true ->
        configured
    end
  end

  defp default_ui_root do
    "lib/#{configured_otp_app() |> Atom.to_string()}/ui"
  end

  defp ui_root_from_generated(ui_root) do
    Path.join(["..", "..", "..", "..", ui_root])
    |> String.replace("\\", "/")
  end

  defp ui_root_from_ui_host(ui_root) do
    Path.join(["..", "..", ui_root])
    |> String.replace("\\", "/")
  end

  defp configured_screen_modules do
    case Application.get_env(:projection, :screen_modules, []) do
      modules when is_list(modules) ->
        modules
        |> Enum.filter(&(is_atom(&1) and not is_nil(&1)))
        |> Enum.filter(&Code.ensure_loaded?/1)

      _other ->
        []
    end
  end

  defp configured_otp_apps do
    case Application.get_env(:projection, :otp_apps) do
      apps when is_list(apps) and apps != [] ->
        apps
        |> Enum.filter(&(is_atom(&1) and not is_nil(&1)))
        |> case do
          [] -> [configured_otp_app()]
          filtered -> filtered
        end

      _ ->
        [configured_otp_app()]
    end
  end

  defp configured_otp_app do
    case Application.get_env(:projection, :otp_app) do
      app when is_atom(app) and not is_nil(app) ->
        app

      _ ->
        case Mix.Project.get() do
          nil ->
            :projection

          _project ->
            case Mix.Project.config()[:app] do
              app when is_atom(app) -> app
              _ -> :projection
            end
        end
    end
  end

  defp build_screen_spec(module) do
    metadata = module.__projection_schema__()
    screen_name = module |> Module.split() |> List.last() |> Macro.underscore()

    fields =
      metadata
      |> Enum.map(&normalize_field!/1)
      |> Enum.sort_by(&Atom.to_string(&1.name))

    unsupported_codegen_fields =
      fields
      |> Enum.reject(&(&1.type in @supported_codegen_types))

    if unsupported_codegen_fields != [] do
      raise_codegen_unsupported_fields!(module, unsupported_codegen_fields)
    end

    codegen_fields =
      fields
      |> Enum.flat_map(&expand_codegen_field/1)

    %{
      module: module,
      module_name: Atom.to_string(module),
      screen_name: screen_name,
      component_name: module |> Module.split() |> List.last() |> Kernel.<>("Screen"),
      file_name: screen_name,
      fields: codegen_fields,
      global_name: camelize(screen_name) <> "State",
      state_file: "#{screen_name}_state.slint"
    }
  end

  defp raise_codegen_unsupported_fields!(module, fields) do
    field_descriptions =
      fields
      |> Enum.map(fn field -> "#{field.name}: #{inspect(field.type)}" end)
      |> Enum.join(", ")

    raise ArgumentError,
          "projection.codegen does not support these schema field types in #{inspect(module)}: " <>
            "#{field_descriptions}. Use typed scalars, :list, :id_table, or `component` fields."
  end

  defp normalize_field!(%{name: name, type: type, default: default, opts: opts})
       when is_atom(name) and type in @supported_schema_types and is_list(opts) do
    cleaned_opts = Keyword.drop(opts, [:direction, :derived, :from, :with])
    %{name: name, type: type, default: default, opts: cleaned_opts}
  end

  defp normalize_field!(%{name: name, type: type, default: default})
       when is_atom(name) and type in @supported_schema_types do
    %{name: name, type: type, default: default, opts: []}
  end

  defp normalize_field!(field) do
    raise ArgumentError,
          "invalid schema field metadata for codegen: #{inspect(field)}"
  end

  defp expand_codegen_field(%{name: name, type: :id_table, default: default, opts: opts}) do
    columns = id_table_columns(opts)

    ids_default = Map.get(default, :order, [])

    id_field = %{
      name: :"#{name}_ids",
      type: :list,
      default: ids_default,
      opts: [items: :string],
      source: %{kind: :id_table, root: name, role: :ids}
    }

    column_fields =
      Enum.map(columns, fn %{name: column_name, type: column_type} = column ->
        column_values_default = id_table_column_values(default, column)

        %{
          name: :"#{name}_#{column_name}",
          type: :list,
          default: column_values_default,
          opts: [items: column_type],
          source: %{kind: :id_table, root: name, role: {:column, column_name}}
        }
      end)

    [id_field | column_fields]
  end

  defp expand_codegen_field(%{name: name, type: :component, default: default, opts: opts}) do
    module = Keyword.fetch!(opts, :module)

    module
    |> component_schema_fields!()
    |> Enum.flat_map(fn component_field ->
      component_default = Map.get(default, component_field.name, component_field.default)
      expand_component_codegen_field(name, component_field, component_default)
    end)
  end

  defp expand_codegen_field(%{name: name, type: type, default: default, opts: opts}) do
    [
      %{
        name: name,
        type: type,
        default: default,
        opts: opts,
        source: %{kind: :direct, root: name}
      }
    ]
  end

  defp expand_component_codegen_field(
         component_root,
         %{name: field_name, type: :id_table, opts: opts},
         component_default
       ) do
    columns = id_table_columns(opts)
    ids_default = Map.get(component_default, :order, [])

    id_field = %{
      name: :"#{component_root}_#{field_name}_ids",
      type: :list,
      default: ids_default,
      opts: [items: :string],
      source: %{
        kind: :component_id_table,
        component: component_root,
        root: field_name,
        role: :ids
      }
    }

    column_fields =
      Enum.map(columns, fn %{name: column_name, type: column_type} = column ->
        column_values_default = id_table_column_values(component_default, column)

        %{
          name: :"#{component_root}_#{field_name}_#{column_name}",
          type: :list,
          default: column_values_default,
          opts: [items: column_type],
          source: %{
            kind: :component_id_table,
            component: component_root,
            root: field_name,
            role: {:column, column_name}
          }
        }
      end)

    [id_field | column_fields]
  end

  defp expand_component_codegen_field(
         component_root,
         %{name: field_name, type: field_type, opts: opts},
         component_default
       ) do
    [
      %{
        name: :"#{component_root}_#{field_name}",
        type: field_type,
        default: component_default,
        opts: opts,
        source: %{kind: :component, component: component_root, field: field_name}
      }
    ]
  end

  defp component_schema_fields!(module) do
    unless function_exported?(module, :__projection_schema__, 0) do
      raise ArgumentError,
            "component module #{inspect(module)} is missing __projection_schema__/0"
    end

    module
    |> apply(:__projection_schema__, [])
    |> Enum.map(&normalize_field!/1)
    |> Enum.sort_by(&Atom.to_string(&1.name))
  end

  defp ensure_apps_loaded!(apps) when is_list(apps) do
    Enum.each(apps, fn app ->
      case Application.load(app) do
        :ok ->
          :ok

        {:error, {:already_loaded, ^app}} ->
          :ok

        {:error, reason} ->
          Mix.raise("failed to load application #{inspect(app)}: #{inspect(reason)}")
      end
    end)
  end

  defp write_file_if_changed(path, content) when is_binary(path) and is_binary(content) do
    case File.read(path) do
      {:ok, existing} when existing == content ->
        :unchanged

      _ ->
        File.write!(path, content)
        :written
    end
  end

  defp unwrap_task_result!({:ok, status}), do: status

  defp unwrap_task_result!({:exit, :timeout}) do
    Mix.raise(
      "projection.codegen worker timed out after #{codegen_task_timeout()}ms. " <>
        "A render function may be hanging. Set PROJECTION_CODEGEN_TIMEOUT=<ms> to adjust."
    )
  end

  defp unwrap_task_result!({:exit, reason}) do
    Mix.raise("projection.codegen worker crashed: #{inspect(reason)}")
  end

  @codegen_task_timeout_default 30_000

  defp codegen_task_timeout do
    case System.get_env("PROJECTION_CODEGEN_TIMEOUT") do
      nil -> @codegen_task_timeout_default
      value -> String.to_integer(value)
    end
  end

  defp max_concurrency do
    System.schedulers_online()
  end

  defp prune_stale_generated_files(generated_dir, specs, app_spec) do
    app_state_files =
      if app_spec, do: ["app_state.rs", "app_state.slint"], else: []

    keep =
      MapSet.new(
        [
          "mod.rs",
          "routes.slint",
          "screen_host.slint",
          "app.slint",
          "error_state.slint"
        ] ++
          app_state_files ++
          Enum.map(specs, &"#{&1.file_name}.rs") ++
          Enum.map(specs, & &1.state_file)
      )

    generated_dir
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.reduce(0, fn path, acc ->
      file_name = Path.basename(path)

      cond do
        not File.regular?(path) ->
          acc

        MapSet.member?(keep, file_name) ->
          acc

        true ->
          File.rm!(path)
          acc + 1
      end
    end)
  end

  defp render_generated_mod([], _routes, app_spec) do
    app_state_mod_line = if app_spec, do: "\n#[rustfmt::skip]\npub mod app_state;\n", else: ""
    app_render_fn = render_app_render_fn(app_spec)

    """
    use crate::AppWindow;
    use projection_ui_host_runtime::PatchOp;
    use serde_json::Value;
    #{app_state_mod_line}
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
    pub enum ScreenId {
        #[default]
        Unknown,
    }

    pub fn apply_render(_ui: &AppWindow, _vm: &Value) -> Result<ScreenId, String> {
        Ok(ScreenId::Unknown)
    }

    pub fn apply_patch(
        _ui: &AppWindow,
        _screen_id: ScreenId,
        _ops: &[PatchOp],
        _vm: &Value,
    ) -> Result<(), String> {
        Ok(())
    }

    #{app_render_fn}
    """
  end

  defp render_generated_mod(specs, routes, app_spec) do
    [first | rest] = specs

    app_state_mod_line = if app_spec, do: "#[rustfmt::skip]\npub mod app_state;", else: ""

    module_lines =
      specs
      |> Enum.map(fn spec -> "pub mod #{spec.file_name};" end)
      |> Enum.map(fn line -> "#[rustfmt::skip]\n#{line}" end)
      |> Enum.join("\n")

    enum_variants =
      rest
      |> Enum.map_join("\n", fn spec ->
        "    #{camelize(spec.screen_name)},"
      end)

    screen_id_names = route_screen_name_map(routes, specs)

    enum_from_vm_arms =
      screen_id_names
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("\n", fn {vm_screen_name, screen_name} ->
        "        Some(\"#{vm_screen_name}\") => ScreenId::#{camelize(screen_name)},"
      end)

    render_dispatch_arms =
      specs
      |> Enum.map_join("\n", fn spec ->
        "        ScreenId::#{camelize(spec.screen_name)} => #{spec.file_name}::apply_render(ui, vm),"
      end)

    patch_dispatch_arms =
      specs
      |> Enum.map_join("\n", fn spec ->
        "        ScreenId::#{camelize(spec.screen_name)} => #{spec.file_name}::apply_patch(ui, ops, vm),"
      end)

    app_render_fn = render_app_render_fn(app_spec)

    """
    use crate::AppWindow;
    use projection_ui_host_runtime::PatchOp;
    use serde_json::Value;

    #{module_lines}
    #{app_state_mod_line}

    #[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
    pub enum ScreenId {
        #[default]
        #{camelize(first.screen_name)},
    #{enum_variants}
    }

    fn screen_id_from_vm(vm: &Value) -> ScreenId {
        match vm.pointer("/screen/name").and_then(Value::as_str) {
    #{enum_from_vm_arms}
            // Fallthrough: unknown screen names map to the first screen as a safe default.
            _ => ScreenId::#{camelize(first.screen_name)},
        }
    }

    pub fn apply_render(ui: &AppWindow, vm: &Value) -> Result<ScreenId, String> {
        let screen_id = screen_id_from_vm(vm);

        match screen_id {
    #{render_dispatch_arms}
        }?;

        Ok(screen_id)
    }

    pub fn apply_patch(ui: &AppWindow, screen_id: ScreenId, ops: &[PatchOp], vm: &Value) -> Result<(), String> {
        match screen_id {
    #{patch_dispatch_arms}
        }
    }

    #{app_render_fn}
    """
  end

  defp render_app_render_fn(app_spec) when app_spec != nil do
    """
    pub fn apply_app_render(ui: &AppWindow, vm: &Value) -> Result<(), String> {
        app_state::apply_render(ui, vm)
    }

    pub fn apply_app_patch(ui: &AppWindow, ops: &[PatchOp], vm: &Value) -> Result<(), String> {
        app_state::apply_patch(ui, ops, vm)
    }
    """
  end

  defp render_app_render_fn(_app_spec) do
    """
    pub fn apply_app_render(_ui: &AppWindow, _vm: &Value) -> Result<(), String> {
        Ok(())
    }

    pub fn apply_app_patch(_ui: &AppWindow, _ops: &[PatchOp], _vm: &Value) -> Result<(), String> {
        Ok(())
    }
    """
  end

  defp route_screen_name_map(routes, specs) do
    screen_name_by_module = Map.new(specs, &{&1.module, &1.screen_name})

    Enum.reduce(routes, %{}, fn route, acc ->
      screen_module = route.screen_module

      case screen_name_by_module do
        %{^screen_module => screen_name} ->
          Map.put(acc, route.name, screen_name)

        _ ->
          raise ArgumentError,
                "route #{inspect(route.name)} references #{inspect(route.screen_module)} without schema metadata"
      end
    end)
  end

  defp render_screen_module(spec) do
    if spec.fields == [] do
      render_empty_screen_module()
    else
      global_name = spec.global_name
      global_type = "crate::#{global_name}"
      direct_fields = Enum.filter(spec.fields, &(&1.source.kind == :direct))
      component_fields = Enum.filter(spec.fields, &(&1.source.kind == :component))
      id_table_fields = Enum.filter(spec.fields, &(&1.source.kind == :id_table))

      component_id_table_fields =
        Enum.filter(spec.fields, &(&1.source.kind == :component_id_table))

      id_table_roots =
        id_table_fields
        |> Enum.group_by(& &1.source.root)
        |> Enum.sort_by(fn {root, _fields} -> Atom.to_string(root) end)

      component_id_table_roots =
        component_id_table_fields
        |> Enum.group_by(fn field -> {field.source.component, field.source.root} end)
        |> Enum.sort_by(fn {{component, root}, _fields} ->
          {Atom.to_string(component), Atom.to_string(root)}
        end)

      component_direct_groups =
        component_fields
        |> Enum.group_by(& &1.source.component)
        |> Map.new(fn {component, fields} ->
          {component, Enum.sort_by(fields, &Atom.to_string(&1.name))}
        end)

      component_id_table_by_component =
        component_id_table_roots
        |> Enum.group_by(fn {{component, _root}, _fields} -> component end)

      component_roots =
        (Map.keys(component_direct_groups) ++ Map.keys(component_id_table_by_component))
        |> Enum.uniq()
        |> Enum.sort_by(&Atom.to_string/1)

      component_root_groups =
        Enum.map(component_roots, fn component ->
          direct_group = Map.get(component_direct_groups, component, [])

          id_table_group =
            component_id_table_by_component
            |> Map.get(component, [])
            |> Enum.sort_by(fn {{_component, root}, _fields} -> Atom.to_string(root) end)

          {component, direct_group, id_table_group}
        end)

      direct_render_setters =
        direct_fields
        |> Enum.map_join("\n", fn field ->
          "        set_#{field.name}_from_vm(&g, screen_vm)?;"
        end)

      component_render_setters =
        component_root_groups
        |> Enum.map_join("\n", fn {component, direct_group, id_table_group} ->
          component_name = Atom.to_string(component)
          component_vm = component_vm_var(component)

          component_direct_setters =
            direct_group
            |> Enum.map_join("\n", fn field ->
              "        set_#{field.name}_from_component(&g, #{component_vm})?;"
            end)

          component_id_table_setters =
            id_table_group
            |> Enum.map_join("\n", fn {{_component, root}, _fields} ->
              "        apply_component_id_table_#{component}_#{root}_from_component(&g, #{component_vm})?;"
            end)

          setters =
            [component_direct_setters, component_id_table_setters]
            |> Enum.reject(&(&1 == ""))
            |> Enum.join("\n")

          """
                  let #{component_vm} = screen_vm
                      .and_then(|root| root.get("#{component_name}"))
                      .and_then(Value::as_object);
          #{setters}
          """
        end)

      id_table_render_setters =
        id_table_roots
        |> Enum.map_join("\n", fn {root, _fields} ->
          "        apply_id_table_#{root}_from_vm(&g, screen_vm)?;"
        end)

      render_field_setters =
        [direct_render_setters, component_render_setters, id_table_render_setters]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")

      patch_apply_lines =
        [
          direct_fields |> Enum.map_join("\n", &render_patch_apply_line/1),
          component_fields |> Enum.map_join("\n", &render_patch_apply_line/1),
          component_root_groups
          |> Enum.map_join("\n", fn {component, direct_group, id_table_group} ->
            render_component_root_patch_apply_line(component, direct_group, id_table_group)
          end),
          id_table_roots |> Enum.map_join("\n", &render_id_table_patch_apply_line/1),
          component_id_table_roots
          |> Enum.map_join("\n", &render_component_id_table_patch_apply_line/1)
        ]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")

      remove_apply_lines =
        [
          direct_fields |> Enum.map_join("\n", &render_remove_apply_line/1),
          component_fields |> Enum.map_join("\n", &render_remove_apply_line/1),
          component_root_groups
          |> Enum.map_join("\n", fn {component, direct_group, id_table_group} ->
            render_component_root_remove_apply_line(component, direct_group, id_table_group)
          end),
          id_table_roots |> Enum.map_join("\n", &render_id_table_remove_apply_line/1),
          component_id_table_roots
          |> Enum.map_join("\n", &render_component_id_table_remove_apply_line/1)
        ]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")

      direct_field_helpers =
        direct_fields
        |> Enum.map_join("\n", &render_field_helper(&1, global_type))

      component_field_helpers =
        component_fields
        |> Enum.map_join("\n", &render_field_helper(&1, global_type))

      id_table_field_helpers =
        id_table_fields
        |> Enum.map_join("\n", &render_field_helper(&1, global_type))

      component_id_table_field_helpers =
        component_id_table_fields
        |> Enum.map_join("\n", &render_field_helper(&1, global_type))

      id_table_root_helpers =
        id_table_roots
        |> Enum.map_join("\n", fn {root, fields} ->
          render_id_table_root_helper(root, fields, global_type)
        end)

      component_id_table_root_helpers =
        component_id_table_roots
        |> Enum.map_join("\n", fn {root_tuple, fields} ->
          render_component_id_table_root_helper(root_tuple, fields, global_type)
        end)

      field_helpers =
        [
          direct_field_helpers,
          component_field_helpers,
          id_table_field_helpers,
          component_id_table_field_helpers,
          id_table_root_helpers,
          component_id_table_root_helpers
        ]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")

      parse_helpers =
        (direct_fields ++ component_fields ++ id_table_fields ++ component_id_table_fields)
        |> Enum.map(&parse_helper_key/1)
        |> Enum.uniq()
        |> Enum.sort_by(&parse_helper_sort_key/1)
        |> Enum.map_join("\n", &render_parse_helper/1)

      id_table_helpers =
        if id_table_fields != [] or component_id_table_fields != [] do
          render_id_table_helpers()
        else
          ""
        end

      patch_screen_vm_line =
        if id_table_roots == [] and component_id_table_roots == [] do
          ""
        else
          "    let screen_vm = vm.pointer(\"/screen/vm\").and_then(Value::as_object);\n"
        end

      patch_vm_param =
        if id_table_roots == [] and component_id_table_roots == [] do
          "_vm"
        else
          "vm"
        end

      needs_value =
        direct_fields != [] or component_fields != [] or component_root_groups != []

      replace_add_pattern =
        if needs_value do
          "PatchOp::Replace { path, value } | PatchOp::Add { path, value }"
        else
          "PatchOp::Replace { path, value: _ } | PatchOp::Add { path, value: _ }"
        end

      """
      use crate::AppWindow;
      use projection_ui_host_runtime::PatchOp;
      use slint::ComponentHandle;
      use serde_json::Value;

      pub fn apply_render(ui: &AppWindow, vm: &Value) -> Result<(), String> {
          let screen_vm = vm.pointer("/screen/vm").and_then(Value::as_object);
          let g = ui.global::<#{global_type}>();
      #{render_field_setters}
          bump_vm_rev(ui);
          Ok(())
      }

      pub fn apply_patch(ui: &AppWindow, ops: &[PatchOp], #{patch_vm_param}: &Value) -> Result<(), String> {
      #{patch_screen_vm_line}
          let g = ui.global::<#{global_type}>();
          for op in ops {
              match op {
                  #{replace_add_pattern} => {
                      let field_path = path.strip_prefix("/screen/vm").unwrap_or(path);
      #{patch_apply_lines}
                  }
                  PatchOp::Remove { path } => {
                      let field_path = path.strip_prefix("/screen/vm").unwrap_or(path);
      #{remove_apply_lines}
                  }
              }
          }

          bump_vm_rev(ui);
          Ok(())
      }

      #{field_helpers}

      fn bump_vm_rev(ui: &AppWindow) {
          let next = ui.get_vm_rev().wrapping_add(1);
          ui.set_vm_rev(next);
      }

      #{parse_helpers}
      #{id_table_helpers}
      """
    end
  end

  defp render_empty_screen_module do
    """
    use crate::AppWindow;
    use projection_ui_host_runtime::PatchOp;
    use serde_json::Value;

    pub fn apply_render(ui: &AppWindow, _vm: &Value) -> Result<(), String> {
        bump_vm_rev(ui);
        Ok(())
    }

    pub fn apply_patch(ui: &AppWindow, _ops: &[PatchOp], _vm: &Value) -> Result<(), String> {
        bump_vm_rev(ui);
        Ok(())
    }

    fn bump_vm_rev(ui: &AppWindow) {
        let next = ui.get_vm_rev().wrapping_add(1);
        ui.set_vm_rev(next);
    }
    """
  end

  defp render_field_helper(
         %{
           name: name,
           type: type,
           default: default,
           opts: opts,
           source: %{kind: :direct}
         },
         global_name
       ) do
    field = Atom.to_string(name)
    default_literal = rust_literal(type, default, opts)
    set_value_expr = rust_set_value_expr(name, type, opts, "g")

    """
    fn set_#{field}_from_vm(
        g: &#{global_name},
        screen_vm: Option<&serde_json::Map<String, Value>>,
    ) -> Result<(), String> {
        if let Some(value) = screen_vm.and_then(|root| root.get("#{field}")) {
            return set_#{field}_from_value(g, "/screen/vm/#{field}", value);
        }

        set_#{field}_default(g);
        Ok(())
    }

    fn set_#{field}_from_value(g: &#{global_name}, path: &str, value: &Value) -> Result<(), String> {
        #{set_value_expr}
    }

    fn set_#{field}_default(g: &#{global_name}) {
        g.set_#{field}(#{default_literal});
    }
    """
  end

  defp render_field_helper(
         %{
           name: name,
           type: type,
           default: default,
           opts: opts,
           source: %{kind: :component, component: component_root, field: component_field}
         },
         global_name
       ) do
    field = Atom.to_string(name)
    component_root_name = Atom.to_string(component_root)
    component_field_name = Atom.to_string(component_field)
    default_literal = rust_literal(type, default, opts)
    set_value_expr = rust_set_value_expr(name, type, opts, "g")

    """
    fn set_#{field}_from_component(
        g: &#{global_name},
        component_vm: Option<&serde_json::Map<String, Value>>,
    ) -> Result<(), String> {
        if let Some(value) = component_vm.and_then(|root| root.get("#{component_field_name}")) {
            return set_#{field}_from_value(g, "/screen/vm/#{component_root_name}/#{component_field_name}", value);
        }

        set_#{field}_default(g);
        Ok(())
    }

    fn set_#{field}_from_value(g: &#{global_name}, path: &str, value: &Value) -> Result<(), String> {
        #{set_value_expr}
    }

    fn set_#{field}_default(g: &#{global_name}) {
        g.set_#{field}(#{default_literal});
    }
    """
  end

  defp render_field_helper(
         %{
           name: name,
           opts: opts,
           default: default,
           source: %{kind: :id_table, root: _root, role: role}
         },
         global_name
       ) do
    field = Atom.to_string(name)
    default_literal = rust_literal(:list, default, opts)
    extract_expr = rust_id_table_extract_expr(role, opts)
    model_expr = rust_list_model_from_values_expr(opts, "values", "path")

    """
    fn set_#{field}_from_parsed(
        g: &#{global_name},
        parsed: &IdTableParsed,
        path: &str,
    ) -> Result<(), String> {
        #{extract_expr}
        #{model_expr}
        g.set_#{field}(slint::ModelRc::new(model));
        Ok(())
    }

    fn set_#{field}_default(g: &#{global_name}) {
        g.set_#{field}(#{default_literal});
    }
    """
  end

  defp render_field_helper(
         %{
           name: name,
           opts: opts,
           default: default,
           source: %{kind: :component_id_table, component: _component, root: _root, role: role}
         },
         global_name
       ) do
    field = Atom.to_string(name)
    default_literal = rust_literal(:list, default, opts)
    extract_expr = rust_id_table_extract_expr(role, opts)
    model_expr = rust_list_model_from_values_expr(opts, "values", "path")

    """
    fn set_#{field}_from_parsed(
        g: &#{global_name},
        parsed: &IdTableParsed,
        path: &str,
    ) -> Result<(), String> {
        #{extract_expr}
        #{model_expr}
        g.set_#{field}(slint::ModelRc::new(model));
        Ok(())
    }

    fn set_#{field}_default(g: &#{global_name}) {
        g.set_#{field}(#{default_literal});
    }
    """
  end

  defp render_patch_apply_line(field) do
    condition = rust_patch_match_condition(field)
    target = Atom.to_string(field.name)

    """
                      if #{condition} {
                          set_#{target}_from_value(&g, path, value)?;
                      }
    """
  end

  defp render_remove_apply_line(field) do
    condition = rust_patch_match_condition(field)
    target = Atom.to_string(field.name)

    """
                      if #{condition} {
                          set_#{target}_default(&g);
                      }
    """
  end

  defp render_component_root_patch_apply_line(component, direct_group, id_table_group) do
    component_name = Atom.to_string(component)
    component_vm = component_vm_var(component)

    direct_setters =
      direct_group
      |> Enum.map_join("\n", fn field ->
        "                      set_#{field.name}_from_component(&g, #{component_vm})?;"
      end)

    id_table_setters =
      id_table_group
      |> Enum.map_join("\n", fn {{_component, root}, _fields} ->
        "                      apply_component_id_table_#{component}_#{root}_from_component(&g, #{component_vm})?;"
      end)

    setters =
      [direct_setters, id_table_setters]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    """
                      if field_path == "/#{component_name}" {
                          let #{component_vm} = value.as_object();
    #{setters}
                      }
    """
  end

  defp render_component_root_remove_apply_line(component, direct_group, id_table_group) do
    component_name = Atom.to_string(component)

    direct_defaults =
      direct_group
      |> Enum.map_join("\n", fn field ->
        "                      set_#{field.name}_default(&g);"
      end)

    id_table_defaults =
      id_table_group
      |> Enum.map_join("\n", fn {{_component, root}, _fields} ->
        "                      apply_component_id_table_#{component}_#{root}_from_component(&g, None)?;"
      end)

    defaults =
      [direct_defaults, id_table_defaults]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    """
                      if field_path == "/#{component_name}" {
    #{defaults}
                      }
    """
  end

  defp render_id_table_patch_apply_line({root, _fields}) do
    root_name = Atom.to_string(root)
    condition = rust_id_table_root_patch_match_condition(root)

    """
                      if #{condition} {
                          apply_id_table_#{root_name}_from_vm(&g, screen_vm)?;
                      }
    """
  end

  defp render_id_table_remove_apply_line({root, _fields}) do
    root_name = Atom.to_string(root)
    condition = rust_id_table_root_patch_match_condition(root)

    """
                      if #{condition} {
                          apply_id_table_#{root_name}_from_vm(&g, screen_vm)?;
                      }
    """
  end

  defp render_component_id_table_patch_apply_line({{component, root}, _fields}) do
    component_name = Atom.to_string(component)
    root_name = Atom.to_string(root)
    condition = rust_component_id_table_patch_match_condition(component, root)
    component_vm = component_vm_var(component)

    """
                      if #{condition} {
                          let #{component_vm} =
                              screen_vm
                                  .and_then(|root| root.get("#{component_name}"))
                                  .and_then(Value::as_object);
                          apply_component_id_table_#{component_name}_#{root_name}_from_component(&g, #{component_vm})?;
                      }
    """
  end

  defp render_component_id_table_remove_apply_line({{component, root}, _fields}) do
    component_name = Atom.to_string(component)
    root_name = Atom.to_string(root)
    condition = rust_component_id_table_patch_match_condition(component, root)
    component_vm = component_vm_var(component)

    """
                      if #{condition} {
                          let #{component_vm} =
                              screen_vm
                                  .and_then(|root| root.get("#{component_name}"))
                                  .and_then(Value::as_object);
                          apply_component_id_table_#{component_name}_#{root_name}_from_component(&g, #{component_vm})?;
                      }
    """
  end

  defp rust_patch_match_condition(%{source: %{kind: :direct, root: root}}) do
    root_name = Atom.to_string(root)
    top_path = "/" <> root_name
    ~s(field_path == "#{top_path}")
  end

  defp rust_patch_match_condition(%{
         source: %{kind: :component, component: component, field: field}
       }) do
    component_name = Atom.to_string(component)
    field_name = Atom.to_string(field)
    ~s(field_path == "/#{component_name}/#{field_name}")
  end

  defp rust_id_table_root_patch_match_condition(root) when is_atom(root) do
    root_name = Atom.to_string(root)
    top_path = "/" <> root_name

    "field_path == \"#{top_path}\" || field_path.starts_with(\"#{top_path}/\")"
  end

  defp rust_component_id_table_patch_match_condition(component, root)
       when is_atom(component) and is_atom(root) do
    component_name = Atom.to_string(component)
    root_name = Atom.to_string(root)
    top_path = "/#{component_name}/#{root_name}"

    "field_path == \"#{top_path}\" || field_path.starts_with(\"#{top_path}/\")"
  end

  defp rust_id_table_extract_expr(:ids, _opts) do
    """
    let _ = path;
    let values = parsed.ids.clone();
    """
  end

  defp rust_id_table_extract_expr({:column, column}, opts) do
    column_name = Atom.to_string(column)
    parse_fn = rust_list_parse_fn(opts)

    """
    let raw_values = parsed
            .columns
            .get("#{column_name}")
            .cloned()
            .ok_or_else(|| format!("missing id_table column '#{column_name}'"))?;
    if raw_values.len() != parsed.ids.len() {
        return Err(format!(
            "inconsistent id_table column '#{column_name}' length: expected {}, got {}",
            parsed.ids.len(),
            raw_values.len()
        ));
    }
    let values = #{parse_fn}(&Value::Array(raw_values), &format!("{path}/#{column_name}"))?;
    """
  end

  defp render_id_table_root_helper(root, fields, global_name) do
    root_name = Atom.to_string(root)

    parsed_setters =
      fields
      |> Enum.map_join("\n", fn field ->
        "    set_#{field.name}_from_parsed(g, &parsed, path)?;"
      end)

    defaults =
      fields
      |> Enum.map_join("\n", fn field ->
        "    set_#{field.name}_default(g);"
      end)

    """
    fn apply_id_table_#{root_name}_from_vm(
        g: &#{global_name},
        screen_vm: Option<&serde_json::Map<String, Value>>,
    ) -> Result<(), String> {
        if let Some(value) = screen_vm.and_then(|root| root.get("#{root_name}")) {
            return apply_id_table_#{root_name}_from_value(g, value, "/screen/vm/#{root_name}");
        }

    #{defaults}
        Ok(())
    }

    fn apply_id_table_#{root_name}_from_value(
        g: &#{global_name},
        value: &Value,
        path: &str,
    ) -> Result<(), String> {
        let parsed = parse_id_table(value, path)?;
    #{parsed_setters}
        Ok(())
    }
    """
  end

  defp render_component_id_table_root_helper({component, root}, fields, global_name) do
    component_name = Atom.to_string(component)
    root_name = Atom.to_string(root)

    parsed_setters =
      fields
      |> Enum.map_join("\n", fn field ->
        "    set_#{field.name}_from_parsed(g, &parsed, path)?;"
      end)

    defaults =
      fields
      |> Enum.map_join("\n", fn field ->
        "    set_#{field.name}_default(g);"
      end)

    """
    fn apply_component_id_table_#{component_name}_#{root_name}_from_component(
        g: &#{global_name},
        component_vm: Option<&serde_json::Map<String, Value>>,
    ) -> Result<(), String> {
        if let Some(value) = component_vm.and_then(|root| root.get("#{root_name}")) {
            return apply_component_id_table_#{component_name}_#{root_name}_from_value(
                g,
                value,
                "/screen/vm/#{component_name}/#{root_name}",
            );
        }

    #{defaults}
        Ok(())
    }

    fn apply_component_id_table_#{component_name}_#{root_name}_from_value(
        g: &#{global_name},
        value: &Value,
        path: &str,
    ) -> Result<(), String> {
        let parsed = parse_id_table(value, path)?;
    #{parsed_setters}
        Ok(())
    }
    """
  end

  defp rust_set_value_expr(name, :string, setter_target) do
    """
    let parsed = parse_string(value, path)?;
        #{setter_target}.set_#{name}(parsed.into());
        Ok(())
    """
  end

  defp rust_set_value_expr(name, :bool, setter_target) do
    """
    let parsed = parse_bool(value, path)?;
        #{setter_target}.set_#{name}(parsed);
        Ok(())
    """
  end

  defp rust_set_value_expr(name, :integer, setter_target) do
    """
    let parsed = parse_integer(value, path)?;
        let casted = i32::try_from(parsed)
            .map_err(|_| format!("value out of range for Slint int at path {path}: {parsed}"))?;
        #{setter_target}.set_#{name}(casted);
        Ok(())
    """
  end

  defp rust_set_value_expr(name, :float, setter_target) do
    """
    let parsed = parse_float(value, path)?;
        let casted = parsed as f32;
        if !casted.is_finite() {
            return Err(format!("non-finite float at path {path}: {parsed}"));
        }
        #{setter_target}.set_#{name}(casted);
        Ok(())
    """
  end

  defp rust_set_value_expr(name, type, _opts, setter_target)
       when type in [:string, :bool, :integer, :float] do
    rust_set_value_expr(name, type, setter_target)
  end

  defp rust_set_value_expr(name, :list, opts, setter_target) do
    parse_fn = rust_list_parse_fn(opts)
    model_expr = rust_list_model_from_values_expr(opts, "parsed", "path")

    """
    let parsed = #{parse_fn}(value, path)?;
        #{model_expr}
        #{setter_target}.set_#{name}(slint::ModelRc::new(model));
        Ok(())
    """
  end

  defp rust_literal(:string, value, _opts), do: "\"#{escape_string(value)}\".into()"
  defp rust_literal(:bool, true, _opts), do: "true"
  defp rust_literal(:bool, false, _opts), do: "false"
  defp rust_literal(:integer, value, _opts), do: "i32::try_from(#{value}i64).unwrap_or_default()"
  defp rust_literal(:float, value, _opts), do: "#{format_float(value)}f32"
  defp rust_literal(:list, value, opts), do: rust_list_literal(value, opts)

  defp escape_string(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp format_float(value) when is_float(value) do
    :erlang.float_to_binary(value, [:compact, decimals: 16])
  end

  defp camelize(value) when is_binary(value) do
    value
    |> Macro.camelize()
    |> String.replace(".", "")
  end

  defp component_vm_var(component) when is_atom(component) do
    suffix =
      component
      |> Atom.to_string()
      |> String.replace(~r/[^A-Za-z0-9_]/, "_")

    "component_" <> suffix
  end

  defp render_parse_helper(:string) do
    """
    fn parse_string(value: &Value, path: &str) -> Result<String, String> {
        value
            .as_str()
            .map(ToOwned::to_owned)
            .ok_or_else(|| format!("expected string at path {path}"))
    }
    """
  end

  defp render_parse_helper(:bool) do
    """
    fn parse_bool(value: &Value, path: &str) -> Result<bool, String> {
        value
            .as_bool()
            .ok_or_else(|| format!("expected bool at path {path}"))
    }
    """
  end

  defp render_parse_helper(:integer) do
    """
    fn parse_integer(value: &Value, path: &str) -> Result<i64, String> {
        value
            .as_i64()
            .ok_or_else(|| format!("expected integer at path {path}"))
    }
    """
  end

  defp render_parse_helper(:float) do
    """
    fn parse_float(value: &Value, path: &str) -> Result<f64, String> {
        value
            .as_f64()
            .ok_or_else(|| format!("expected float at path {path}"))
    }
    """
  end

  defp render_parse_helper(:list), do: render_parse_helper({:list, :string})

  defp render_parse_helper({:list, :string}) do
    """
    fn parse_string_list(value: &Value, path: &str) -> Result<Vec<String>, String> {
        let items = value
            .as_array()
            .ok_or_else(|| format!("expected list at path {path}"))?;

        items
            .iter()
            .enumerate()
            .map(|(index, entry)| {
                entry
                    .as_str()
                    .map(ToOwned::to_owned)
                    .ok_or_else(|| format!("expected string at path {path}[{index}]"))
            })
            .collect()
    }
    """
  end

  defp render_parse_helper({:list, :integer}) do
    """
    fn parse_integer_list(value: &Value, path: &str) -> Result<Vec<i64>, String> {
        let items = value
            .as_array()
            .ok_or_else(|| format!("expected list at path {path}"))?;

        items
            .iter()
            .enumerate()
            .map(|(index, entry)| {
                entry
                    .as_i64()
                    .ok_or_else(|| format!("expected integer at path {path}[{index}]"))
            })
            .collect()
    }
    """
  end

  defp render_parse_helper({:list, :float}) do
    """
    fn parse_float_list(value: &Value, path: &str) -> Result<Vec<f64>, String> {
        let items = value
            .as_array()
            .ok_or_else(|| format!("expected list at path {path}"))?;

        items
            .iter()
            .enumerate()
            .map(|(index, entry)| {
                entry
                    .as_f64()
                    .ok_or_else(|| format!("expected float at path {path}[{index}]"))
            })
            .collect()
    }
    """
  end

  defp render_parse_helper({:list, :bool}) do
    """
    fn parse_bool_list(value: &Value, path: &str) -> Result<Vec<bool>, String> {
        let items = value
            .as_array()
            .ok_or_else(|| format!("expected list at path {path}"))?;

        items
            .iter()
            .enumerate()
            .map(|(index, entry)| {
                entry
                    .as_bool()
                    .ok_or_else(|| format!("expected bool at path {path}[{index}]"))
            })
            .collect()
    }
    """
  end

  defp render_id_table_helpers do
    """
    struct IdTableParsed {
        ids: Vec<String>,
        columns: std::collections::BTreeMap<String, Vec<Value>>,
    }

    fn parse_id_table(value: &Value, path: &str) -> Result<IdTableParsed, String> {
        let object = value
            .as_object()
            .ok_or_else(|| format!("expected id_table object at path {path}"))?;

        let order = object
            .get("order")
            .and_then(Value::as_array)
            .ok_or_else(|| format!("missing id_table order at path {path}"))?;

        let by_id = object
            .get("by_id")
            .and_then(Value::as_object)
            .ok_or_else(|| format!("missing id_table by_id at path {path}"))?;

        let mut ids = Vec::with_capacity(order.len());
        let mut columns: std::collections::BTreeMap<String, Vec<Value>> =
            std::collections::BTreeMap::new();

        for (index, id_value) in order.iter().enumerate() {
            let id = id_value
                .as_str()
                .ok_or_else(|| format!("expected id string at path {path}/order/{index}"))?
                .to_owned();

            let row = by_id
                .get(&id)
                .and_then(Value::as_object)
                .ok_or_else(|| format!("missing id_table row for id '{id}' at path {path}"))?;

            ids.push(id);

            for (column, column_value) in row {
                columns
                    .entry(column.clone())
                    .or_insert_with(Vec::new)
                    .push(column_value.clone());
            }
        }

        Ok(IdTableParsed { ids, columns })
    }
    """
  end

  defp render_routes_slint(routes) do
    route_props =
      routes
      |> Enum.map_join("\n", fn route ->
        "    out property <string> #{slint_identifier(route.route_key)}: \"#{escape_slint_string(route.name)}\";"
      end)

    """
    // generated by mix projection.codegen; do not edit manually
    export global Routes {
    #{route_props}
    }
    """
  end

  defp render_screen_state_slint(spec) do
    property_lines =
      spec.fields
      |> Enum.map_join("\n", fn field ->
        opts = Map.get(field, :opts, [])

        "    in property <#{slint_type(field.type, opts)}> #{field.name}: #{slint_literal(field.type, field.default, opts)};"
      end)

    """
    // generated by mix projection.codegen; do not edit manually
    export global #{spec.global_name} {
    #{property_lines}
    }
    """
  end

  defp render_error_state_slint do
    property_lines =
      error_state_fields()
      |> Enum.map_join("\n", fn field ->
        opts = Map.get(field, :opts, [])

        "    in property <#{slint_type(field.type, opts)}> #{field.name}: #{slint_literal(field.type, field.default, opts)};"
      end)

    """
    // generated by mix projection.codegen; do not edit manually
    export global ErrorState {
    #{property_lines}
    }
    """
  end

  defp render_app_state_slint(app_spec) do
    property_lines =
      app_spec.fields
      |> Enum.map_join("\n", fn field ->
        opts = Map.get(field, :opts, [])

        "    in property <#{slint_type(field.type, opts)}> #{field.name}: #{slint_literal(field.type, field.default, opts)};"
      end)

    """
    // generated by mix projection.codegen; do not edit manually
    export global AppState {
    #{property_lines}
    }
    """
  end

  defp render_app_state_module(app_spec) do
    if app_spec.fields == [] do
      render_empty_app_state_module()
    else
      global_name = app_spec.global_name
      global_type = "crate::#{global_name}"
      fields = app_spec.fields

      # App state only supports direct fields (no components or id_tables expected, but use same expand_codegen_field)
      direct_fields = Enum.filter(fields, &(&1.source.kind == :direct))

      render_setters =
        direct_fields
        |> Enum.map_join("\n", fn field ->
          "        set_#{field.name}_from_vm(&g, app_vm)?;"
        end)

      patch_apply_lines =
        direct_fields
        |> Enum.map_join("\n", fn field ->
          field_name = Atom.to_string(field.name)

          """
                          if field_path == "/#{field_name}" {
                              set_#{field_name}_from_value(&g, path, value)?;
                          }
          """
        end)

      remove_apply_lines =
        direct_fields
        |> Enum.map_join("\n", fn field ->
          field_name = Atom.to_string(field.name)

          """
                          if field_path == "/#{field_name}" {
                              set_#{field_name}_default(&g);
                          }
          """
        end)

      field_helpers =
        direct_fields
        |> Enum.map_join("\n", fn field ->
          render_app_state_field_helper(field, global_type)
        end)

      parse_helpers =
        direct_fields
        |> Enum.map(&parse_helper_key/1)
        |> Enum.uniq()
        |> Enum.sort_by(&parse_helper_sort_key/1)
        |> Enum.map_join("\n", &render_parse_helper/1)

      """
      use crate::AppWindow;
      use projection_ui_host_runtime::PatchOp;
      use slint::ComponentHandle;
      use serde_json::Value;

      pub fn apply_render(ui: &AppWindow, vm: &Value) -> Result<(), String> {
          let app_vm = vm.pointer("/app").and_then(Value::as_object);
          let g = ui.global::<#{global_type}>();
      #{render_setters}
          Ok(())
      }

      pub fn apply_patch(ui: &AppWindow, ops: &[PatchOp], _vm: &Value) -> Result<(), String> {
          let g = ui.global::<#{global_type}>();
          for op in ops {
              match op {
                  PatchOp::Replace { path, value } | PatchOp::Add { path, value } => {
                      let field_path = path.strip_prefix("/app").unwrap_or(path);
      #{patch_apply_lines}
                  }
                  PatchOp::Remove { path } => {
                      let field_path = path.strip_prefix("/app").unwrap_or(path);
      #{remove_apply_lines}
                  }
              }
          }

          Ok(())
      }

      #{field_helpers}

      #{parse_helpers}
      """
    end
  end

  defp render_empty_app_state_module do
    """
    use crate::AppWindow;
    use projection_ui_host_runtime::PatchOp;
    use serde_json::Value;

    pub fn apply_render(_ui: &AppWindow, _vm: &Value) -> Result<(), String> {
        Ok(())
    }

    pub fn apply_patch(_ui: &AppWindow, _ops: &[PatchOp], _vm: &Value) -> Result<(), String> {
        Ok(())
    }
    """
  end

  defp render_app_state_field_helper(
         %{name: name, type: type, default: default, opts: opts, source: %{kind: :direct}},
         global_name
       ) do
    field = Atom.to_string(name)
    default_literal = rust_literal(type, default, opts)
    set_value_expr = rust_set_value_expr(name, type, opts, "g")

    """
    fn set_#{field}_from_vm(
        g: &#{global_name},
        app_vm: Option<&serde_json::Map<String, Value>>,
    ) -> Result<(), String> {
        if let Some(value) = app_vm.and_then(|root| root.get("#{field}")) {
            return set_#{field}_from_value(g, "/app/#{field}", value);
        }

        set_#{field}_default(g);
        Ok(())
    }

    fn set_#{field}_from_value(g: &#{global_name}, path: &str, value: &Value) -> Result<(), String> {
        #{set_value_expr}
    }

    fn set_#{field}_default(g: &#{global_name}) {
        g.set_#{field}(#{default_literal});
    }
    """
  end

  defp render_build_rs(specs, ui_root_from_ui_host, app_spec) do
    state_rerun_lines =
      specs
      |> Enum.map(fn spec ->
        "    println!(\"cargo:rerun-if-changed=src/generated/#{spec.state_file}\");"
      end)
      |> Enum.sort()

    app_state_rerun_lines =
      if app_spec do
        [
          "    println!(\"cargo:rerun-if-changed=src/generated/app_state.slint\");"
        ]
      else
        []
      end

    base_lines = [
      "fn main() {",
      "    slint_build::compile(\"src/generated/app.slint\").expect(\"failed to compile app.slint\");",
      "",
      "    println!(\"cargo:rerun-if-changed=src/generated/app.slint\");",
      "    println!(\"cargo:rerun-if-changed=src/generated/screen_host.slint\");",
      "    println!(\"cargo:rerun-if-changed=src/generated/routes.slint\");",
      "    println!(\"cargo:rerun-if-changed=src/generated/error_state.slint\");"
    ]

    (base_lines ++
       state_rerun_lines ++
       app_state_rerun_lines ++
       ["    println!(\"cargo:rerun-if-changed=#{ui_root_from_ui_host}/\");", "}"])
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp render_screen_host_slint(specs, routes, ui_root_from_generated) do
    active_screen_default = default_active_screen(routes)

    spec_by_module = Map.new(specs, &{&1.module, &1})

    routes_with_specs =
      Enum.map(routes, fn route ->
        screen_module = route.screen_module

        case spec_by_module do
          %{^screen_module => spec} ->
            {route, spec}

          _ ->
            raise ArgumentError,
                  "route #{inspect(route.name)} references #{inspect(route.screen_module)} without schema metadata"
        end
      end)

    screen_import_lines =
      routes_with_specs
      |> Enum.map(fn {_route, spec} ->
        "import { #{spec.component_name} } from \"#{ui_root_from_generated}/#{spec.file_name}.slint\";"
      end)
      |> Enum.uniq()
      |> Enum.sort()

    state_import_lines =
      specs
      |> Enum.map(fn spec ->
        "import { #{spec.global_name} } from \"#{spec.state_file}\";"
      end)
      |> Enum.sort()

    import_lines =
      (screen_import_lines ++ state_import_lines)
      |> Enum.join("\n")

    route_branch_lines =
      routes_with_specs
      |> Enum.map_join("\n", fn {route, spec} ->
        render_screen_host_route_branch(route, spec)
      end)

    """
    // generated by mix projection.codegen; do not edit manually
    #{import_lines}
    import { ErrorScreen } from "#{ui_root_from_generated}/error.slint";
    import { ErrorState } from "error_state.slint";
    import { Routes } from "routes.slint";

    export component ScreenHost inherits VerticalLayout {
        in property <int> vm_rev: 0;
        in property <string> active_screen: "#{escape_slint_string(active_screen_default)}";
        callback ui_intent(intent_name: string, intent_arg: string);
        callback navigate(route_name: string, params_json: string);

        spacing: 0px;

    #{route_branch_lines}

        if root.active_screen == "error": ErrorScreen {
            title: ErrorState.error_title;
            message: ErrorState.error_message;
            screen_module: ErrorState.error_screen_module;
        }
    }
    """
  end

  defp id_table_columns(opts) when is_list(opts) do
    opts
    |> Keyword.get(:columns, [])
    |> Enum.map(&normalize_id_table_column!/1)
  end

  defp id_table_columns(_opts), do: []

  defp normalize_id_table_column!(%{name: name, type: type})
       when is_atom(name) and type in [:string, :integer, :float, :bool] do
    %{name: name, type: type}
  end

  defp normalize_id_table_column!({name, type})
       when is_atom(name) and type in [:string, :integer, :float, :bool] do
    %{name: name, type: type}
  end

  defp normalize_id_table_column!(column) do
    raise ArgumentError,
          "invalid id_table column metadata for codegen: #{inspect(column)}"
  end

  defp id_table_column_values(%{order: order, by_id: by_id}, %{name: column, type: column_type})
       when is_list(order) and is_map(by_id) and is_atom(column) and
              column_type in [:string, :integer, :float, :bool] do
    Enum.map(order, fn id ->
      row = Map.get(by_id, id, %{})

      value =
        cond do
          is_map(row) and Map.has_key?(row, column) ->
            Map.get(row, column)

          is_map(row) and Map.has_key?(row, Atom.to_string(column)) ->
            Map.get(row, Atom.to_string(column))

          true ->
            nil
        end

      normalize_id_table_column_value(value, column_type)
    end)
  end

  defp id_table_column_values(_default, _column), do: []

  defp normalize_id_table_column_value(value, :string) when is_binary(value), do: value
  defp normalize_id_table_column_value(value, :integer) when is_integer(value), do: value
  defp normalize_id_table_column_value(value, :float) when is_float(value), do: value
  defp normalize_id_table_column_value(value, :bool) when is_boolean(value), do: value

  defp normalize_id_table_column_value(_value, :string), do: ""
  defp normalize_id_table_column_value(_value, :integer), do: 0
  defp normalize_id_table_column_value(_value, :float), do: 0.0
  defp normalize_id_table_column_value(_value, :bool), do: false

  defp render_screen_host_route_branch(route, spec) do
    route_id = slint_identifier(route.route_key)
    state_name = spec.global_name

    field_bindings =
      spec.fields
      |> Enum.map_join("\n", fn field ->
        "            #{field.name}: #{state_name}.#{field.name};"
      end)

    """
        if root.active_screen == Routes.#{route_id}: #{spec.component_name} {
    #{field_bindings}
        }
    """
  end

  defp slint_identifier(route_key) when is_atom(route_key) do
    route_key
    |> Atom.to_string()
    |> String.replace(~r/[^A-Za-z0-9_]/, "_")
    |> ensure_non_numeric_identifier()
  end

  defp ensure_non_numeric_identifier(""), do: "route"

  defp ensure_non_numeric_identifier(identifier) do
    case identifier do
      <<first::utf8, _rest::binary>> when first in ?0..?9 -> "route_" <> identifier
      _ -> identifier
    end
  end

  defp escape_slint_string(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp slint_type(:string, _opts), do: "string"
  defp slint_type(:bool, _opts), do: "bool"
  defp slint_type(:integer, _opts), do: "int"
  defp slint_type(:float, _opts), do: "float"

  defp slint_type(:list, opts) do
    item_type =
      opts
      |> list_item_type()
      |> slint_list_item_type()

    "[#{item_type}]"
  end

  defp slint_literal(:string, value, _opts), do: "\"#{escape_slint_string(value)}\""
  defp slint_literal(:bool, true, _opts), do: "true"
  defp slint_literal(:bool, false, _opts), do: "false"
  defp slint_literal(:integer, value, _opts), do: Integer.to_string(value)
  defp slint_literal(:float, value, _opts), do: format_float(value)
  defp slint_literal(:list, value, opts), do: slint_list_literal(value, opts)

  defp render_generated_app_slint(specs, routes, ui_root_from_generated, app_spec) do
    active_screen_default = default_active_screen(routes)

    state_export_lines =
      specs
      |> Enum.map(fn spec ->
        "export { #{spec.global_name} } from \"#{spec.state_file}\";"
      end)
      |> Enum.sort()
      |> Enum.join("\n")

    app_state_export_line =
      if app_spec do
        "export { AppState } from \"app_state.slint\";"
      else
        ""
      end

    # AppShell owns navigation chrome. Wire active_tab and navigate through the shell.
    shell_nav_props = """
            active_tab: root.active_screen;
            navigate(route) => { root.navigate(route, "{}"); }
    """

    """
    // generated by mix projection.codegen; do not edit manually
    import { AppShell } from "#{ui_root_from_generated}/app_shell.slint";
    import { ScreenHost } from "screen_host.slint";
    export { UI } from "#{ui_root_from_generated}/ui.slint";
    #{state_export_lines}
    export { ErrorState } from "error_state.slint";
    #{app_state_export_line}

    export component AppWindow inherits Window {
        in property <int> vm_rev: 0;
        in property <string> app_title: "Projection";
        in property <string> active_screen: "#{escape_slint_string(active_screen_default)}";
        in property <bool> nav_can_back: false;

        callback ui_intent(intent_name: string, intent_arg: string);
        callback navigate(route_name: string, params_json: string);

        shell := AppShell {
            app_title: root.app_title;
            show_back: root.nav_can_back;
            nav_back => { root.ui_intent("ui.back", ""); }
    #{shell_nav_props}
            ScreenHost {
                vm_rev: root.vm_rev;
                active_screen: root.active_screen;
                ui_intent(intent_name, intent_arg) => { root.ui_intent(intent_name, intent_arg); }
                navigate(route_name, params_json) => { root.navigate(route_name, params_json); }
            }
        }

        width: shell.window_width;
        height: shell.window_height;
        background: #1a1a2e;
    }
    """
  end

  defp default_active_screen([%{name: name} | _]) when is_binary(name), do: name
  defp default_active_screen(_routes), do: "error"

  defp error_state_fields do
    [
      %{name: :error_title, type: :string, default: "Rendering Error"},
      %{name: :error_message, type: :string, default: ""},
      %{name: :error_screen_module, type: :string, default: ""}
    ]
  end

  defp parse_helper_key(%{type: :list, opts: opts}), do: {:list, list_item_type(opts)}
  defp parse_helper_key(%{type: type}), do: type

  defp parse_helper_sort_key({:list, item_type}), do: {1, item_type}
  defp parse_helper_sort_key(type), do: {0, type}

  defp list_item_type(opts) when is_list(opts) do
    case Keyword.get(opts, :items, :string) do
      type when type in [:string, :integer, :float, :bool] -> type
      other -> raise ArgumentError, "unsupported list item type for codegen: #{inspect(other)}"
    end
  end

  defp list_item_type(_opts), do: :string

  defp slint_list_item_type(:string), do: "string"
  defp slint_list_item_type(:integer), do: "int"
  defp slint_list_item_type(:float), do: "float"
  defp slint_list_item_type(:bool), do: "bool"

  defp slint_list_literal(values, opts) when is_list(values) do
    item_type = list_item_type(opts)

    values
    |> Enum.map(&slint_list_item_literal(&1, item_type))
    |> Enum.join(", ")
    |> then(&"[#{&1}]")
  end

  defp slint_list_item_literal(value, :string) when is_binary(value),
    do: "\"#{escape_slint_string(value)}\""

  defp slint_list_item_literal(value, :integer) when is_integer(value),
    do: Integer.to_string(value)

  defp slint_list_item_literal(value, :float) when is_float(value),
    do: format_float(value)

  defp slint_list_item_literal(true, :bool), do: "true"
  defp slint_list_item_literal(false, :bool), do: "false"

  defp slint_list_item_literal(value, item_type) do
    raise ArgumentError,
          "expected list default items of #{inspect(item_type)}, got: #{inspect(value)}"
  end

  defp rust_list_literal(values, opts) when is_list(values) do
    item_type = list_item_type(opts)
    items = Enum.map_join(values, ", ", &rust_list_item_literal(&1, item_type))

    "slint::ModelRc::new(slint::VecModel::from(vec![#{items}]))"
  end

  defp rust_list_item_literal(value, :string) when is_binary(value),
    do: "\"#{escape_string(value)}\".into()"

  defp rust_list_item_literal(value, :integer) when is_integer(value),
    do: "i32::try_from(#{value}i64).unwrap_or_default()"

  defp rust_list_item_literal(value, :float) when is_float(value),
    do: "#{format_float(value)}f32"

  defp rust_list_item_literal(true, :bool), do: "true"
  defp rust_list_item_literal(false, :bool), do: "false"

  defp rust_list_item_literal(value, item_type) do
    raise ArgumentError,
          "expected list default items of #{inspect(item_type)}, got: #{inspect(value)}"
  end

  defp rust_list_parse_fn(opts) do
    case list_item_type(opts) do
      :string -> "parse_string_list"
      :integer -> "parse_integer_list"
      :float -> "parse_float_list"
      :bool -> "parse_bool_list"
    end
  end

  defp rust_list_model_from_values_expr(opts, values_var, path_var) do
    case list_item_type(opts) do
      :string ->
        """
        let model = slint::VecModel::from(
            #{values_var}
                .into_iter()
                .map(slint::SharedString::from)
                .collect::<Vec<slint::SharedString>>(),
        );
        """

      :integer ->
        """
        let values = #{values_var}
            .into_iter()
            .map(|entry| {
                i32::try_from(entry)
                    .map_err(|_| format!("value out of range for Slint int at path {#{path_var}}: {entry}"))
            })
            .collect::<Result<Vec<i32>, String>>()?;
        let model = slint::VecModel::from(values);
        """

      :float ->
        """
        let values = #{values_var}
            .into_iter()
            .map(|entry| {
                let casted = entry as f32;
                if casted.is_finite() {
                    Ok(casted)
                } else {
                    Err(format!("non-finite float at path {#{path_var}}: {entry}"))
                }
            })
            .collect::<Result<Vec<f32>, String>>()?;
        let model = slint::VecModel::from(values);
        """

      :bool ->
        """
        let model = slint::VecModel::from(#{values_var});
        """
    end
  end
end
