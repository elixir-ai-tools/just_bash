defmodule JustBash.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/elixir-ai-tools/just_bash"
  @description "A simulated bash environment with virtual filesystem for safe command execution"

  def project do
    [
      app: :just_bash,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: @description,
      package: package(),
      docs: docs(),
      dialyzer: [
        plt_add_apps: [:mix],
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
      name: "JustBash",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def cli do
    [preferred_envs: [dialyzer: :dev, credo: :dev]]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {JustBash.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "eval", "test/support"]
  defp elixirc_paths(_), do: ["lib", "eval"]

  defp deps do
    [
      {:telemetry, "~> 0.4 or ~> 1.0"},
      {:nimble_parsec, "~> 1.4"},
      {:nimble_options, "~> 1.1"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:earmark, "~> 1.4"},
      {:exgit, github: "ivarvong/exgit", only: [:dev, :test]},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.0", only: [:dev, :test]},
      {:benchee, "~> 1.0", only: :dev}
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
      maintainers: ["Ivar Vong", "Chris Bell", "Dave Lucia"],
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
