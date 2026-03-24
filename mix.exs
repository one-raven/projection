defmodule Projection.MixProject do
  use Mix.Project

  def project do
    [
      app: :projection,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      compilers: Mix.compilers(),
      deps: deps(),
      description: "Elixir-authoritative UI for native and embedded apps, rendered by Slint.",
      source_url: "https://github.com/isaiahp/projection",
      docs: [main: "readme", extras: ["README.md"]],
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"},
      {:ex_doc, "~> 0.37", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/isaiahp/projection"},
      files: ~w(
        lib
        slint/ui_host_runtime/Cargo.toml
        slint/ui_host_runtime/Cargo.lock
        slint/ui_host_runtime/src/lib.rs
        slint/ui_host_runtime/src/protocol.rs
        mix.exs
        mix.lock
        README.md
        LICENSE
        .formatter.exs
      )
    ]
  end
end
