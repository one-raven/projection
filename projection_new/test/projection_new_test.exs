defmodule ProjectionNewTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  test "generates a starter project" do
    target = tmp_dir("projection_new_starter")
    on_exit(fn -> File.rm_rf(target) end)

    output =
      capture_io(fn ->
        Mix.Tasks.Projection.New.run([target, "--module", "StarterApp", "--app", "starter_app"])
      end)

    assert output =~ "created successfully"

    assert File.regular?(Path.join(target, "mix.exs"))
    assert File.regular?(Path.join(target, "config/config.exs"))
    assert File.regular?(Path.join(target, "lib/starter_app/router.ex"))
    assert File.regular?(Path.join(target, "lib/starter_app/screens/hello.ex"))
    assert File.regular?(Path.join(target, "lib/starter_app/ui/app_shell.slint"))
    assert File.regular?(Path.join(target, "lib/starter_app/ui/error.slint"))
    assert File.regular?(Path.join(target, "lib/starter_app/ui/screen.slint"))
    assert File.regular?(Path.join(target, "lib/starter_app/ui/ui.slint"))
    assert File.regular?(Path.join(target, "lib/starter_app/ui/hello.slint"))
    assert File.regular?(Path.join(target, "slint/ui_host/src/main.rs"))
    refute File.exists?(Path.join(target, "slint/ui_host/src/protocol.rs"))
    refute File.exists?(Path.join(target, "slint/ui_host/src/patch_apply.rs"))

    mix_exs = File.read!(Path.join(target, "mix.exs"))
    assert mix_exs =~ "app: :starter_app"
    assert mix_exs =~ "compilers: Mix.compilers() ++ [:projection_codegen, :projection_ui_host]"

    ui_host_main = File.read!(Path.join(target, "slint/ui_host/src/main.rs"))
    assert ui_host_main =~ "projection_ui_host_runtime::app_main!"

    ui_host_cargo = File.read!(Path.join(target, "slint/ui_host/Cargo.toml"))
    assert ui_host_cargo =~ "../../deps/projection/slint/ui_host_runtime"

    app_shell = File.read!(Path.join(target, "lib/starter_app/ui/app_shell.slint"))
    assert app_shell =~ "in property <length> window_width"
    assert app_shell =~ "in property <length> window_height"

    demo_ex = File.read!(Path.join(target, "lib/starter_app/demo.ex"))
    assert demo_ex =~ "Path.join(\"ui_host/ui_host\" <> suffix)"
  end

  test "refuses non-empty destination without --force" do
    target = tmp_dir("projection_new_non_empty")
    on_exit(fn -> File.rm_rf(target) end)
    File.mkdir_p!(target)
    File.write!(Path.join(target, "existing.txt"), "x")

    assert_raise Mix.Error, ~r/already exists and is not empty/, fn ->
      Mix.Tasks.Projection.New.run([target])
    end
  end

  defp tmp_dir(prefix) do
    id = System.unique_integer([:positive])
    Path.join(System.tmp_dir!(), "#{prefix}_#{id}")
  end
end
