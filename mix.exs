defmodule JustBash.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/ivarvong/just_bash"
  @description "A simulated bash environment with virtual filesystem for safe command execution"

  def project do
    [
      app: :just_bash,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: @description,
      package: package(),
      docs: docs(),
      dialyzer: [plt_add_apps: [:mix]],
      name: "JustBash",
      source_url: @source_url,
      homepage_url: @source_url,
      preferred_cli_env: [
        dialyzer: :dev,
        credo: :dev
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {JustBash.Application, []}
    ]
  end

  defp deps do
    [
      {:nimble_parsec, "~> 1.4"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.0", only: [:dev, :test]}
    ]
  end

  defp package do
    [
      name: "just_bash",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      maintainers: ["Your Name"],
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      name: "JustBash",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md", "CONTRIBUTING.md", "LICENSE"],
      groups_for_modules: [
        Core: [JustBash],
        Parser: [JustBash.Parser, JustBash.Parser.Lexer, JustBash.Parser.WordParts],
        AST: [JustBash.AST],
        Filesystem: [JustBash.Fs, JustBash.Fs.InMemoryFs],
        Utilities: [JustBash.Arithmetic]
      ]
    ]
  end
end
