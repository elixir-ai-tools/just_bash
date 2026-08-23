defmodule JustBash.MixProject do
  use Mix.Project

  @version "1.0.0"
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
      {:telemetry, "~> 1.3"},
      {:vfs, "~> 0.1.0"},
      {:nimble_parsec, "~> 1.4"},
      {:nimble_options, "~> 1.1"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:mdex, "~> 0.13"},
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
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md UPGRADING.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      name: "JustBash",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "UPGRADING.md", "CHANGELOG.md", "CONTRIBUTING.md", "LICENSE"],
      groups_for_extras: [
        Guides: ["README.md", "UPGRADING.md"],
        Project: ["CHANGELOG.md", "CONTRIBUTING.md", "LICENSE"]
      ],
      # The eval harness lives in `eval/` and is compiled for dev/test only — it is
      # not part of the published Hex package (see `package/0`), so it must not be
      # documented on HexDocs.
      filter_modules: fn module, _metadata ->
        not String.starts_with?(inspect(module), "JustBash.Eval.")
      end,
      # Groups are rendered in the order listed, so this sequence is the sidebar
      # itself: consumer-facing API first, implementation long tails last.
      # Patterns may be module atoms or regexes matched against the module name;
      # the first matching group wins, so narrower patterns come first.
      groups_for_modules: [
        Core: [
          JustBash,
          JustBash.Result,
          JustBash.Sigil,
          JustBash.Limit,
          JustBash.Telemetry
        ],
        Exceptions: [
          JustBash.Limit.ExceededError,
          JustBash.Parser.ParseError,
          JustBash.Parser.Lexer.Error,
          JustBash.Interpreter.Expansion.UnsetVariableError
        ],
        Filesystem: [
          JustBash.FS,
          JustBash.FS.Memory,
          JustBash.FS.POSIX
        ],
        "HTTP & Network": [
          JustBash.Network,
          JustBash.HttpClient,
          JustBash.HttpClient.Default
        ],
        "Custom Commands": [
          JustBash.Commands.Command,
          JustBash.Commands.Registry,
          JustBash.Commands.ArgParser,
          JustBash.FlagParser
        ],
        "Declarative CLIs": [~r/^JustBash\.CLI($|\.)/],
        "Parsing & Formatting": [
          JustBash.Parser,
          JustBash.Formatter
        ],
        "Command Internals": [~r/^JustBash\.Commands\.(Awk|Jq|Sed)\./],
        "Built-in Commands": [~r/^JustBash\.Commands\./],
        "Parser & Lexer": [~r/^JustBash\.Parser\./],
        Interpreter: [~r/^JustBash\.Interpreter($|\.)/],
        Arithmetic: [~r/^JustBash\.Arithmetic($|\.)/],
        AST: [~r/^JustBash\.AST($|\.)/],
        "Security Auditing": [JustBash.BannedCallTracer],
        "Spec Test Harness": [~r/^JustBash\.SpecTest($|\.)/],
        "Mix Tasks": [~r/^Mix\.Tasks\./]
      ],
      nest_modules_by_prefix: [
        JustBash.Arithmetic,
        JustBash.AST,
        JustBash.CLI,
        JustBash.Commands,
        JustBash.Commands.Awk,
        JustBash.Commands.Jq,
        JustBash.Commands.Sed,
        JustBash.FS,
        JustBash.HttpClient,
        JustBash.Interpreter,
        JustBash.Interpreter.Executor,
        JustBash.Interpreter.Expansion,
        JustBash.Parser,
        JustBash.Parser.Lexer,
        JustBash.Parser.WordParts,
        JustBash.SpecTest
      ]
    ]
  end
end
