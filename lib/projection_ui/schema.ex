defmodule ProjectionUI.Schema do
  @moduledoc """
  Typed view-model schema DSL for screen modules.

  Every screen must declare a `schema` block listing the fields visible to
  the UI host. These declarations drive codegen (Rust setters) and compile-time
  validation.

  ## Supported types

    * `:string` — default `""`
    * `:bool` — default `false`
    * `:integer` — default `0`
    * `:float` — default `0.0`
    * `:map` — default `%{}`
    * `:list` — default `[]` (`items: :string | :integer | :float | :bool`, default `:string`)
    * `:id_table` — default `%{order: [], by_id: %{}}` (`columns: [name: :string, ...]`)

  Component fields are declared with `component/2,3` (not `field/3`):

      component :status_badge, MyApp.Components.StatusBadge

  ## Collection guidance

  `:list` is intended for small or low-churn collections. For larger lists
  where row-level updates matter, prefer `:id_table` so patches can target
  stable IDs instead of replacing full lists.

  ## Example

      schema do
        field :greeting, :string, default: "Hello!"
        field :count, :integer
        field :tiles, :list, items: :integer, default: [1, 2, 3]
      end

  """

  @allowed_types [:string, :bool, :integer, :float, :map, :list, :id_table]
  @component_supported_types [:string, :bool, :integer, :float, :list, :id_table]
  @list_item_types [:string, :integer, :float, :bool]
  @id_table_column_types [:string, :integer, :float, :bool]

  defmacro __using__(opts) do
    owner = Keyword.get(opts, :owner)

    if owner in [:screen, :component, :app_state] do
      Module.put_attribute(__CALLER__.module, :projection_schema_owner, owner)
    end

    quote do
      import ProjectionUI.Schema,
        only: [schema: 1, field: 2, field: 3, component: 2, component: 3]

      Module.register_attribute(__MODULE__, :projection_schema_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :projection_schema_declared, persist: false)
      @projection_schema_declared false
      @before_compile ProjectionUI.Schema
    end
  end

  @doc """
  Declares the screen's view-model schema.

  Must appear exactly once in each screen module. Can be empty if the screen
  has no fields:

      schema do
      end

  """
  defmacro schema(do: block) do
    quote do
      @projection_schema_declared true
      unquote(block)
    end
  end

  @doc """
  Declares a named, typed field inside a `schema` block.

  Accepts an optional `:default` value. If omitted, the type's zero-value is
  used (e.g. `""` for `:string`, `0` for `:integer`).
  """
  defmacro field(name, type, opts \\ []) do
    caller = __CALLER__
    expanded_name = Macro.expand(name, caller)
    expanded_type = Macro.expand(type, caller)
    expanded_opts = expand_literal!(opts, caller, "field options")

    validate_name!(expanded_name, caller)
    validate_type!(expanded_type, caller)
    validate_opts!(expanded_type, expanded_opts, caller)

    default =
      case Keyword.fetch(expanded_opts, :default) do
        {:ok, value} -> value
        :error -> default_for_type(expanded_type)
      end

    normalized_opts =
      expanded_type
      |> normalize_field_opts(expanded_opts)
      |> Keyword.put(:default, default)

    validate_default!(expanded_name, expanded_type, default, normalized_opts, caller)

    quote do
      @projection_schema_fields {unquote(expanded_name), unquote(expanded_type),
                                 unquote(Macro.escape(normalized_opts))}
    end
  end

  @doc """
  Declares a reusable component field inside a `schema` block.

  The component module must use `ProjectionUI, :component` and declare a
  non-empty schema using supported component field types.
  """
  defmacro component(name, module, opts \\ []) do
    caller = __CALLER__
    expanded_name = Macro.expand(name, caller)
    expanded_module = Macro.expand(module, caller)
    expanded_opts = expand_literal!(opts, caller, "component options")

    validate_name!(expanded_name, caller)
    validate_component_context!(caller)
    validate_component_opts!(expanded_opts, caller)

    {component_opts, default} =
      normalize_component_definition!(expanded_name, expanded_module, expanded_opts, caller)

    normalized_opts = Keyword.put(component_opts, :default, default)

    quote do
      @projection_schema_fields {unquote(expanded_name), :component,
                                 unquote(Macro.escape(normalized_opts))}
    end
  end

  defmacro __before_compile__(env) do
    ensure_schema_declared!(env)

    normalized_schema =
      env.module
      |> Module.get_attribute(:projection_schema_fields)
      |> Enum.reverse()
      |> normalize_schema!(env)

    defaults = Map.new(normalized_schema, fn field -> {field.name, field.default} end)

    quote do
      @doc false
      @spec schema() :: map()
      def schema, do: unquote(Macro.escape(defaults))

      @doc false
      @spec __projection_schema__() :: [map()]
      def __projection_schema__, do: unquote(Macro.escape(normalized_schema))
    end
  end

  @doc """
  Validates that a screen module's `render/1` output matches its schema.

  Raises `ArgumentError` if keys or types don't match. Used by the codegen
  task to catch mismatches at build time.
  """
  @spec validate_render!(module()) :: :ok
  def validate_render!(module) when is_atom(module) do
    ensure_exported!(module, :schema, 0)
    ensure_exported!(module, :render, 1)
    ensure_exported!(module, :__projection_schema__, 0)

    schema_defaults = module.schema()
    metadata = module.__projection_schema__()
    rendered = module.render(schema_defaults)

    unless is_map(rendered) do
      raise ArgumentError,
            "#{inspect(module)}.render/1 must return a map, got: #{inspect(rendered)}"
    end

    expected_keys = metadata |> Enum.map(& &1.name) |> Enum.sort()
    rendered_keys = rendered |> Map.keys() |> Enum.sort()

    if expected_keys != rendered_keys do
      raise ArgumentError,
            "#{inspect(module)}.render/1 keys #{inspect(rendered_keys)} " <>
              "do not match schema keys #{inspect(expected_keys)}"
    end

    Enum.each(metadata, fn field ->
      name = field.name
      type = field.type
      opts = Map.get(field, :opts, [])
      value = Map.fetch!(rendered, name)

      unless value_matches_type?(type, value, opts) do
        raise ArgumentError,
              "#{inspect(module)}.render/1 returned invalid value for #{inspect(name)} " <>
                "(expected #{inspect(type)}, got #{inspect(value)})"
      end
    end)

    :ok
  end

  defp normalize_schema!(fields, env) do
    fields
    |> Enum.map(fn {name, type, opts} ->
      default = Keyword.fetch!(opts, :default)
      base = %{name: name, type: type, default: default}
      extra_opts = Keyword.delete(opts, :default)
      if extra_opts == [], do: base, else: Map.put(base, :opts, extra_opts)
    end)
    |> detect_duplicates!(env)
    |> Enum.sort_by(&Atom.to_string(&1.name))
  end

  defp detect_duplicates!(fields, env) do
    duplicated_names =
      fields
      |> Enum.group_by(& &1.name)
      |> Enum.filter(fn {_name, entries} -> length(entries) > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicated_names != [] do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "duplicate schema fields: #{inspect(Enum.sort(duplicated_names))}"
    end

    fields
  end

  defp ensure_exported!(module, function, arity) do
    unless function_exported?(module, function, arity) do
      raise ArgumentError,
            "#{inspect(module)} must export #{function}/#{arity} for schema validation"
    end
  end

  defp expand_literal!(quoted, caller, label) do
    expanded =
      quoted
      |> Macro.expand(caller)
      |> normalize_signed_numeric_literals()

    if Macro.quoted_literal?(expanded) do
      {value, _binding} = Code.eval_quoted(expanded, [], caller)
      value
    else
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description: "#{label} must be compile-time literals, got: #{Macro.to_string(quoted)}"
    end
  end

  # Elixir parses signed numeric literals as unary operator AST nodes (e.g. -1
  # becomes {:-, _, [1]}), which are not considered quoted literals. Normalize
  # these nodes to plain numeric values before literal validation.
  defp normalize_signed_numeric_literals(quoted) do
    Macro.prewalk(quoted, fn
      {:-, _meta, [value]} when is_integer(value) or is_float(value) ->
        -value

      {:+, _meta, [value]} when is_integer(value) or is_float(value) ->
        value

      other ->
        other
    end)
  end

  defp ensure_schema_declared!(env) do
    declared? = Module.get_attribute(env.module, :projection_schema_declared)

    unless declared? do
      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "#{inspect(env.module)} must declare `schema do ... end` (it can be empty if needed)"
    end
  end

  defp validate_name!(name, _caller) when is_atom(name), do: :ok

  defp validate_name!(name, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "schema field name must be an atom, got: #{inspect(name)}"
  end

  defp validate_type!(type, _caller) when type in @allowed_types, do: :ok

  defp validate_type!(type, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description:
        "unsupported schema type #{inspect(type)}. Allowed types: #{inspect(@allowed_types)}"
  end

  defp validate_opts!(:id_table, opts, caller) when is_list(opts) do
    unknown_keys =
      opts
      |> Keyword.keys()
      |> Enum.uniq()
      |> Enum.reject(&(&1 in [:default, :columns]))

    if unknown_keys != [] do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description:
          "unsupported id_table field options: #{inspect(unknown_keys)} (supported: [:default, :columns])"
    end

    case Keyword.fetch(opts, :columns) do
      {:ok, columns} ->
        validate_id_table_columns!(columns, caller)

      :error ->
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description:
            ":id_table fields require typed columns, for example `columns: [name: :string, status: :string]`"
    end
  end

  defp validate_opts!(:list, opts, caller) when is_list(opts) do
    unknown_keys =
      opts
      |> Keyword.keys()
      |> Enum.uniq()
      |> Enum.reject(&(&1 in [:default, :items]))

    if unknown_keys != [] do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description:
          "unsupported list field options: #{inspect(unknown_keys)} (supported: [:default, :items])"
    end

    case Keyword.get(opts, :items, :string) do
      type when type in @list_item_types ->
        :ok

      invalid ->
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description:
            ":list fields require `items:` to be one of #{inspect(@list_item_types)}, got: #{inspect(invalid)}"
    end
  end

  defp validate_opts!(_type, opts, _caller) when is_list(opts), do: :ok

  defp validate_opts!(_type, opts, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "field options must be a keyword list, got: #{inspect(opts)}"
  end

  defp validate_default!(name, type, default, opts, caller) do
    unless value_matches_type?(type, default, opts) do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description:
          "invalid default for #{inspect(name)}. Expected #{inspect(type)}, got #{inspect(default)}"
    end
  end

  defp value_matches_type?(:string, value, _opts), do: is_binary(value)
  defp value_matches_type?(:bool, value, _opts), do: is_boolean(value)
  defp value_matches_type?(:integer, value, _opts), do: is_integer(value)
  defp value_matches_type?(:float, value, _opts), do: is_float(value)
  defp value_matches_type?(:map, value, _opts), do: is_map(value)

  defp value_matches_type?(:list, value, opts) when is_list(value) and is_list(opts) do
    item_type = list_item_type(opts)
    Enum.all?(value, &list_item_matches?(item_type, &1))
  end

  defp value_matches_type?(:list, _value, _opts), do: false
  defp value_matches_type?(:id_table, value, opts), do: valid_id_table?(value, opts)
  defp value_matches_type?(:component, value, opts), do: valid_component_value?(value, opts)

  defp normalize_field_opts(:id_table, opts) when is_list(opts) do
    columns =
      opts
      |> Keyword.get(:columns, [])
      |> normalize_id_table_columns()

    Keyword.put(opts, :columns, columns)
  end

  defp normalize_field_opts(_type, opts), do: opts

  defp default_for_type(:string), do: ""
  defp default_for_type(:bool), do: false
  defp default_for_type(:integer), do: 0
  defp default_for_type(:float), do: 0.0
  defp default_for_type(:map), do: %{}
  defp default_for_type(:list), do: []
  defp default_for_type(:id_table), do: %{order: [], by_id: %{}}

  defp list_item_type(opts) when is_list(opts), do: Keyword.get(opts, :items, :string)

  defp list_item_matches?(:string, value), do: is_binary(value)
  defp list_item_matches?(:integer, value), do: is_integer(value)
  defp list_item_matches?(:float, value), do: is_float(value)
  defp list_item_matches?(:bool, value), do: is_boolean(value)

  defp valid_id_table?(%{order: order, by_id: by_id}, opts)
       when is_list(order) and is_map(by_id) and is_list(opts) do
    columns = id_table_columns(opts)

    columns != [] and
      Enum.all?(order, &is_binary/1) and
      Enum.all?(order, fn id ->
        row = Map.get(by_id, id)
        is_map(row) and Enum.all?(columns, &id_table_cell_matches?(row, &1))
      end)
  end

  defp valid_id_table?(_value, _opts), do: false

  defp validate_id_table_columns!(columns, caller) when is_list(columns) do
    unless columns != [] and Keyword.keyword?(columns) do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description:
          ":id_table fields require typed columns, for example `columns: [name: :string, status: :string]`"
    end

    duplicate_columns =
      columns
      |> Keyword.keys()
      |> Enum.group_by(& &1)
      |> Enum.filter(fn {_name, entries} -> length(entries) > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicate_columns != [] do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description: "duplicate id_table columns: #{inspect(Enum.sort(duplicate_columns))}"
    end

    Enum.each(columns, fn {column_name, column_type} ->
      unless column_type in @id_table_column_types do
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description:
            ":id_table columns must use one of #{inspect(@id_table_column_types)}, got #{inspect(column_name)}: #{inspect(column_type)}"
      end
    end)
  end

  defp validate_id_table_columns!(_columns, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description:
        ":id_table fields require typed columns, for example `columns: [name: :string, status: :string]`"
  end

  defp normalize_id_table_columns(columns) when is_list(columns) do
    Enum.map(columns, fn {name, type} -> %{name: name, type: type} end)
  end

  defp id_table_columns(opts) when is_list(opts) do
    opts
    |> Keyword.get(:columns, [])
    |> Enum.reduce_while([], fn
      %{name: name, type: type}, acc when is_atom(name) and type in @id_table_column_types ->
        {:cont, [%{name: name, type: type} | acc]}

      {name, type}, acc when is_atom(name) and type in @id_table_column_types ->
        {:cont, [%{name: name, type: type} | acc]}

      _other, _acc ->
        {:halt, :invalid}
    end)
    |> case do
      :invalid -> []
      columns -> Enum.reverse(columns)
    end
  end

  defp id_table_columns(_opts), do: []

  defp id_table_cell_matches?(row, %{name: column_name, type: column_type})
       when is_map(row) and is_atom(column_name) and column_type in @id_table_column_types do
    case fetch_id_table_cell(row, column_name) do
      {:ok, value} -> list_item_matches?(column_type, value)
      :error -> false
    end
  end

  defp fetch_id_table_cell(row, column_name) when is_map(row) and is_atom(column_name) do
    case Map.fetch(row, column_name) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        Map.fetch(row, Atom.to_string(column_name))
    end
  end

  defp validate_component_context!(caller) do
    owner = Module.get_attribute(caller.module, :projection_schema_owner)
    behaviours = caller.module |> Module.get_attribute(:behaviour) |> List.wrap()

    screen_context? = owner == :screen or ProjectionUI.Screen in behaviours

    unless screen_context? do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description:
          "nested `component` declarations are not supported in v1 (component module: #{inspect(caller.module)})"
    end
  end

  defp validate_component_opts!(opts, caller) when is_list(opts) do
    unknown_keys =
      opts
      |> Keyword.keys()
      |> Enum.uniq()
      |> Enum.reject(&(&1 in [:default]))

    if unknown_keys != [] do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description:
          "unsupported component options: #{inspect(unknown_keys)} (supported: [:default])"
    end
  end

  defp validate_component_opts!(opts, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "component options must be a keyword list, got: #{inspect(opts)}"
  end

  defp normalize_component_definition!(name, module, opts, caller) do
    validate_component_module!(module, caller)

    component_schema = component_schema!(module, caller)

    if component_schema == [] do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description:
          "component #{inspect(name)} references #{inspect(module)} with no schema fields"
    end

    unsupported_types =
      component_schema
      |> Enum.map(& &1.type)
      |> Enum.uniq()
      |> Enum.reject(&(&1 in @component_supported_types))

    if unsupported_types != [] do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description:
          "component #{inspect(module)} uses unsupported field types for v1: #{inspect(unsupported_types)}. " <>
            "Supported: #{inspect(@component_supported_types)}"
    end

    component_defaults =
      case module.schema() do
        defaults when is_map(defaults) ->
          defaults

        other ->
          raise CompileError,
            file: caller.file,
            line: caller.line,
            description:
              "component #{inspect(module)}.schema/0 must return a map, got: #{inspect(other)}"
      end

    default_overrides = Keyword.get(opts, :default, %{})

    unless is_map(default_overrides) do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description:
          "component #{inspect(name)} default override must be a map, got: #{inspect(default_overrides)}"
    end

    unless Enum.all?(Map.keys(default_overrides), &is_atom/1) do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description:
          "component #{inspect(name)} default override keys must be atoms, got: #{inspect(Map.keys(default_overrides))}"
    end

    unknown_override_keys =
      default_overrides
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(component_defaults, &1))

    if unknown_override_keys != [] do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description:
          "component #{inspect(name)} has unknown default keys: #{inspect(unknown_override_keys)}"
    end

    merged_default = Map.merge(component_defaults, default_overrides)

    Enum.each(component_schema, fn field ->
      field_name = field.name
      field_value = Map.get(merged_default, field_name)
      field_opts = Map.get(field, :opts, [])

      unless value_matches_type?(field.type, field_value, field_opts) do
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description:
            "invalid component default for #{inspect(name)}.#{field_name}: " <>
              "expected #{inspect(field.type)}, got #{inspect(field_value)}"
      end
    end)

    {[module: module], merged_default}
  end

  defp validate_component_module!(module, caller) when is_atom(module) do
    case Code.ensure_compiled(module) do
      {:module, _module} ->
        :ok

      {:error, reason} ->
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description: "failed to compile component module #{inspect(module)}: #{inspect(reason)}"
    end

    unless function_exported?(module, :__projection_component__, 0) do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description: "component module #{inspect(module)} must use `ProjectionUI, :component`"
    end
  end

  defp validate_component_module!(module, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "component module must be an alias atom, got: #{inspect(module)}"
  end

  defp component_schema!(module, caller) do
    unless function_exported?(module, :__projection_schema__, 0) do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description: "component module #{inspect(module)} must export __projection_schema__/0"
    end

    case module.__projection_schema__() do
      schema when is_list(schema) ->
        schema

      other ->
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description:
            "component module #{inspect(module)} returned invalid schema metadata: #{inspect(other)}"
    end
  end

  defp valid_component_value?(value, opts) when is_map(value) and is_list(opts) do
    with module when is_atom(module) <- Keyword.get(opts, :module),
         true <- function_exported?(module, :__projection_schema__, 0) do
      schema = module.__projection_schema__()
      expected_keys = schema |> Enum.map(& &1.name) |> Enum.sort()
      value_keys = value |> Map.keys() |> Enum.sort()

      expected_keys == value_keys and
        Enum.all?(schema, fn field ->
          field_opts = Map.get(field, :opts, [])

          case Map.fetch(value, field.name) do
            {:ok, field_value} -> value_matches_type?(field.type, field_value, field_opts)
            :error -> false
          end
        end)
    else
      _ -> false
    end
  end

  defp valid_component_value?(_value, _opts), do: false
end
