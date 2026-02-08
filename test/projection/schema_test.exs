defmodule Projection.SchemaTest do
  use ExUnit.Case, async: false

  alias ProjectionUI.Schema
  alias Projection.Session

  defmodule DemoScreen do
    use ProjectionUI, :screen

    schema do
      field(:title, :string, default: "Ready")
      field(:enabled, :bool, default: true)
      field(:count, :integer, default: 7)
      field(:ratio, :float, default: 1.5)
    end

    @impl true
    def mount(_params, _session, state), do: {:ok, state}

    @impl true
    def handle_event(_event, _params, state), do: {:noreply, state}

    @impl true
    def handle_info(_message, state), do: {:noreply, state}

    @impl true
    def render(assigns) do
      %{
        count: Map.get(assigns, :count, 7),
        enabled: Map.get(assigns, :enabled, true),
        ratio: Map.get(assigns, :ratio, 1.5),
        title: Map.get(assigns, :title, "Ready")
      }
    end
  end

  defmodule ContainerScreen do
    use ProjectionUI, :screen

    schema do
      field(:devices, :map, default: %{order: [], by_id: %{}})
      field(:tabs, :list, default: ["clock"])
    end

    @impl true
    def render(assigns), do: assigns
  end

  defmodule SignedDefaultsScreen do
    use ProjectionUI, :screen

    schema do
      field(:offset, :integer, default: -7)
      field(:ratio, :float, default: -1.5)
      field(:meta, :map, default: %{delta: -2, scale: -0.75})
      field(:items, :list, items: :integer, default: [-1, -2, -3])
    end
  end

  defmodule TypedListScreen do
    use ProjectionUI, :screen

    schema do
      field(:tiles, :list, items: :integer, default: [1, 2, 3])
      field(:ratios, :list, items: :float, default: [1.0, 0.5])
      field(:flags, :list, items: :bool, default: [true, false])
      field(:tabs, :list, default: ["clock", "devices"])
    end

    @impl true
    def render(assigns), do: assigns
  end

  defmodule TypedIdTableScreen do
    use ProjectionUI, :screen

    schema do
      field(:devices, :id_table,
        columns: [name: :string, status: :string, pos: :integer, load: :float, online: :bool],
        default: %{
          order: ["dev-1", "dev-2"],
          by_id: %{
            "dev-1" => %{name: "Kitchen", status: "Online", pos: 1, load: 0.5, online: true},
            "dev-2" => %{name: "Door", status: "Offline", pos: 2, load: 0.0, online: false}
          }
        }
      )
    end

    @impl true
    def render(assigns), do: assigns
  end

  defmodule StatusBadgeComponent do
    use ProjectionUI, :component

    schema do
      field(:label, :string, default: "Badge")
      field(:status, :string, default: "ok")
    end
  end

  defmodule ComponentScreen do
    use ProjectionUI, :screen

    schema do
      field(:title, :string, default: "Dashboard")
      component(:badge, StatusBadgeComponent, default: %{label: "API"})
    end

    @impl true
    def render(assigns), do: assigns
  end

  test "schema/0 returns defaults and metadata is normalized" do
    assert DemoScreen.schema() == %{
             count: 7,
             enabled: true,
             ratio: 1.5,
             title: "Ready"
           }

    assert DemoScreen.__projection_schema__() == [
             %{name: :count, type: :integer, default: 7},
             %{name: :enabled, type: :bool, default: true},
             %{name: :ratio, type: :float, default: 1.5},
             %{name: :title, type: :string, default: "Ready"}
           ]
  end

  test "validate_render!/1 validates type and key contract" do
    assert :ok == Schema.validate_render!(DemoScreen)
  end

  test "schema supports map and list fields" do
    assert ContainerScreen.schema() == %{
             devices: %{order: [], by_id: %{}},
             tabs: ["clock"]
           }

    assert ContainerScreen.__projection_schema__() == [
             %{name: :devices, type: :map, default: %{order: [], by_id: %{}}},
             %{name: :tabs, type: :list, default: ["clock"]}
           ]

    assert :ok == Schema.validate_render!(ContainerScreen)
  end

  test "schema accepts signed numeric literals in defaults" do
    assert SignedDefaultsScreen.schema() == %{
             offset: -7,
             ratio: -1.5,
             meta: %{delta: -2, scale: -0.75},
             items: [-1, -2, -3]
           }

    assert SignedDefaultsScreen.__projection_schema__() == [
             %{name: :items, type: :list, default: [-1, -2, -3], opts: [items: :integer]},
             %{name: :meta, type: :map, default: %{delta: -2, scale: -0.75}},
             %{name: :offset, type: :integer, default: -7},
             %{name: :ratio, type: :float, default: -1.5}
           ]
  end

  test "schema supports typed list items" do
    assert TypedListScreen.schema() == %{
             flags: [true, false],
             ratios: [1.0, 0.5],
             tabs: ["clock", "devices"],
             tiles: [1, 2, 3]
           }

    assert TypedListScreen.__projection_schema__() == [
             %{name: :flags, type: :list, default: [true, false], opts: [items: :bool]},
             %{name: :ratios, type: :list, default: [1.0, 0.5], opts: [items: :float]},
             %{name: :tabs, type: :list, default: ["clock", "devices"]},
             %{name: :tiles, type: :list, default: [1, 2, 3], opts: [items: :integer]}
           ]

    assert :ok == Schema.validate_render!(TypedListScreen)
  end

  test "schema supports typed id_table columns and normalized metadata" do
    assert TypedIdTableScreen.schema() == %{
             devices: %{
               order: ["dev-1", "dev-2"],
               by_id: %{
                 "dev-1" => %{name: "Kitchen", status: "Online", pos: 1, load: 0.5, online: true},
                 "dev-2" => %{name: "Door", status: "Offline", pos: 2, load: 0.0, online: false}
               }
             }
           }

    assert [
             %{
               name: :devices,
               type: :id_table,
               default: default,
               opts: [columns: columns]
             }
           ] = TypedIdTableScreen.__projection_schema__()

    assert default == TypedIdTableScreen.schema()[:devices]

    assert columns == [
             %{name: :name, type: :string},
             %{name: :status, type: :string},
             %{name: :pos, type: :integer},
             %{name: :load, type: :float},
             %{name: :online, type: :bool}
           ]

    assert :ok == Schema.validate_render!(TypedIdTableScreen)
  end

  test "schema rejects unsupported typed id_table column types" do
    module_name = :"InvalidIdTableColumnType#{System.unique_integer([:positive])}"
    module = Module.concat([Projection, module_name])

    assert_raise CompileError, ~r/:id_table columns must use one of/, fn ->
      Code.compile_string("""
      defmodule #{inspect(module)} do
        use ProjectionUI, :screen
        schema do
          field(:devices, :id_table, columns: [meta: :map], default: %{order: [], by_id: %{}})
        end
      end
      """)
    end
  end

  test "schema rejects id_table defaults that do not match typed columns" do
    module_name = :"InvalidIdTableDefault#{System.unique_integer([:positive])}"
    module = Module.concat([Projection, module_name])

    assert_raise CompileError, ~r/invalid default for :devices/, fn ->
      Code.compile_string("""
      defmodule #{inspect(module)} do
        use ProjectionUI, :screen
        schema do
          field(:devices, :id_table,
            columns: [name: :string, pos: :integer],
            default: %{
              order: ["dev-1"],
              by_id: %{
                "dev-1" => %{name: "Kitchen", pos: "1"}
              }
            }
          )
        end
      end
      """)
    end
  end

  test "schema rejects invalid :list item type option" do
    module_name = :"InvalidListItems#{System.unique_integer([:positive])}"
    module = Module.concat([Projection, module_name])

    assert_raise CompileError, ~r/:list fields require `items:` to be one of/, fn ->
      Code.compile_string("""
      defmodule #{inspect(module)} do
        use ProjectionUI, :screen
        schema do
          field(:values, :list, items: :map, default: [])
        end
      end
      """)
    end
  end

  test "schema rejects list defaults that do not match item type" do
    module_name = :"InvalidListDefault#{System.unique_integer([:positive])}"
    module = Module.concat([Projection, module_name])

    assert_raise CompileError, ~r/invalid default for :values/, fn ->
      Code.compile_string("""
      defmodule #{inspect(module)} do
        use ProjectionUI, :screen
        schema do
          field(:values, :list, items: :integer, default: ["1", "2"])
        end
      end
      """)
    end
  end

  test "schema supports reusable component fields" do
    assert ComponentScreen.schema() == %{
             badge: %{label: "API", status: "ok"},
             title: "Dashboard"
           }

    assert [
             %{
               default: %{label: "API", status: "ok"},
               name: :badge,
               type: :component,
               opts: opts
             },
             %{default: "Dashboard", name: :title, type: :string}
           ] = ComponentScreen.__projection_schema__()

    assert Keyword.fetch!(opts, :module) == StatusBadgeComponent
    assert :ok == Schema.validate_render!(ComponentScreen)
  end

  test "screen modules must declare schema do/end" do
    module_name = :"MissingSchema#{System.unique_integer([:positive])}"
    module = Module.concat([Projection, module_name])

    source = """
    defmodule #{inspect(module)} do
      use ProjectionUI, :screen
    end
    """

    assert_raise CompileError, ~r/must declare `schema do \.\.\. end`/, fn ->
      Code.compile_string(source)
    end
  end

  test "nested components are rejected at compile time" do
    inner_name = :"InnerComp#{System.unique_integer([:positive])}"
    inner_mod = Module.concat([Projection, inner_name])

    Code.compile_string("""
    defmodule #{inspect(inner_mod)} do
      use ProjectionUI, :component
      schema do
        field(:label, :string, default: "x")
      end
    end
    """)

    outer_name = :"OuterComp#{System.unique_integer([:positive])}"
    outer_mod = Module.concat([Projection, outer_name])

    assert_raise CompileError, ~r/nested.*component.*not supported/, fn ->
      Code.compile_string("""
      defmodule #{inspect(outer_mod)} do
        use ProjectionUI, :component
        schema do
          component(:nested, #{inspect(inner_mod)})
        end
      end
      """)
    end
  end

  test "empty component schema is rejected at compile time" do
    empty_name = :"EmptyComp#{System.unique_integer([:positive])}"
    empty_mod = Module.concat([Projection, empty_name])

    Code.compile_string("""
    defmodule #{inspect(empty_mod)} do
      use ProjectionUI, :component
      schema do
      end
    end
    """)

    screen_name = :"EmptyCompScreen#{System.unique_integer([:positive])}"
    screen_mod = Module.concat([Projection, screen_name])

    assert_raise CompileError, ~r/no schema fields/, fn ->
      Code.compile_string("""
      defmodule #{inspect(screen_mod)} do
        use ProjectionUI, :screen
        schema do
          component(:badge, #{inspect(empty_mod)})
        end
      end
      """)
    end
  end

  test "validate_render! rejects invalid component values" do
    screen_name = :"BadCompRender#{System.unique_integer([:positive])}"
    screen_mod = Module.concat([Projection, screen_name])

    Code.compile_string("""
    defmodule #{inspect(screen_mod)} do
      use ProjectionUI, :screen
      schema do
        component(:badge, #{inspect(StatusBadgeComponent)})
      end

      @impl true
      def render(_assigns) do
        %{badge: "not_a_map"}
      end
    end
    """)

    assert_raise ArgumentError, ~r/invalid value.*badge/, fn ->
      Schema.validate_render!(screen_mod)
    end
  end

  test "session seeds mount state from schema defaults" do
    {:ok, session} =
      start_supervised(
        {Session,
         [
           sid: "S1",
           screen_module: DemoScreen
         ]}
      )

    assert {:ok, [render]} =
             Session.handle_ui_envelope_sync(session, %{"t" => "ready", "sid" => "S1"})

    assert render["vm"][:title] == "Ready"
    assert render["vm"][:enabled] == true
    assert render["vm"][:count] == 7
    assert render["vm"][:ratio] == 1.5
  end
end
