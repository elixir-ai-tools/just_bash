defmodule JustBash.CLI.RoutingTest do
  use ExUnit.Case, async: true

  alias JustBash.CLI
  alias JustBash.Commands.Command

  # A small CLI exercised through the full shell, the way a host would register it.
  #
  #   acme pr review --report N [--format text|json] [-v]
  #   acme pr open <id>
  #   acme product list
  #   acme whoami            (reads bash.context)
  defp acme do
    CLI.new("acme",
      doc: "Acme operations toolkit",
      aliases: ["ac"],
      commands: [
        CLI.command("pr",
          doc: "Pull request management",
          commands: [
            CLI.command("review",
              doc: "Review a pull request",
              flags: [
                report: [type: :integer, required: true, doc: "Report ID"],
                format: [type: :string, default: "text", values: ~w(text json), doc: "Format"],
                verbose: [type: :boolean, short: "-v"]
              ],
              run: fn inv ->
                tag = if inv.flags.verbose, do: "VERBOSE ", else: ""
                out = "#{tag}review report=#{inv.flags.report} format=#{inv.flags.format}\n"
                {Command.ok(out), inv.bash}
              end
            ),
            CLI.command("open",
              doc: "Open a pull request",
              args: [%{name: :id, required: true, doc: "PR id"}],
              run: fn inv -> {Command.ok("open #{Enum.join(inv.args, ",")}\n"), inv.bash} end
            )
          ]
        ),
        CLI.command("product",
          doc: "Product lifecycle",
          commands: [
            CLI.command("list",
              doc: "List products",
              run: fn inv -> {Command.ok("p1\np2\n"), inv.bash} end
            )
          ]
        ),
        CLI.command("whoami",
          doc: "Print the current user from context",
          run: fn inv -> {Command.ok("#{inv.bash.context.user}\n"), inv.bash} end
        )
      ]
    )
  end

  defp run(script, opts \\ []) do
    bash = JustBash.new(Keyword.merge([commands: %{"acme" => acme()}], opts))
    {result, _bash} = JustBash.exec(bash, script)
    result
  end

  describe "registration" do
    test "a CLI struct registers as a command" do
      result = run("acme product list")
      assert result.stdout == "p1\np2\n"
      assert result.exit_code == 0
    end

    test "registering under an alias not in name/aliases raises" do
      assert_raise ArgumentError, ~r/registered as "nope"/, fn ->
        JustBash.new(commands: %{"nope" => acme()})
      end
    end

    test "a CLI cannot override a protected builtin" do
      cli = CLI.new("cd", commands: [CLI.command("x", run: fn i -> {Command.ok(), i.bash} end)])

      assert_raise ArgumentError, ~r/protected builtin/, fn ->
        JustBash.new(commands: %{"cd" => cli})
      end
    end
  end

  describe "routing" do
    test "routes a nested leaf and parses typed flags" do
      result = run("acme pr review --report 42 --format json")
      assert result.stdout == "review report=42 format=json\n"
      assert result.exit_code == 0
    end

    test "applies flag defaults" do
      result = run("acme pr review --report 7")
      assert result.stdout == "review report=7 format=text\n"
    end

    test "supports short boolean flags" do
      result = run("acme pr review --report 7 -v")
      assert result.stdout == "VERBOSE review report=7 format=text\n"
    end

    test "binds positional arguments" do
      result = run("acme pr open 123")
      assert result.stdout == "open 123\n"
    end

    test "handlers retain access to bash.context" do
      result = run("acme whoami", context: %{user: "dave"})
      assert result.stdout == "dave\n"
    end

    test "a leading -- is consumed as an options terminator before a subcommand" do
      result = run("acme -- pr review --report 5")
      assert result.exit_code == 0
      assert result.stdout == "review report=5 format=text\n"
    end
  end

  describe "errors" do
    test "unknown subcommand exits 2 with a hint" do
      result = run("acme pr nope")
      assert result.exit_code == 2
      assert result.stderr =~ "unknown command 'pr nope'"
      # The help pointer targets the group the unknown token sat under, not the root.
      assert result.stderr =~ "Run 'acme pr --help'"
    end

    test "missing required flag exits 2" do
      result = run("acme pr review")
      assert result.exit_code == 2
      assert result.stderr =~ "missing required flag: --report"
    end

    test "invalid enum value exits 2" do
      result = run("acme pr review --report 1 --format yaml")
      assert result.exit_code == 2
      assert result.stderr =~ "invalid value for --format: yaml"
    end

    test "missing required positional exits 2" do
      result = run("acme pr open")
      assert result.exit_code == 2
      assert result.stderr =~ "missing required argument: id"
    end

    test "too many positionals exits 2" do
      result = run("acme pr open 1 2")
      assert result.exit_code == 2
      assert result.stderr =~ "unexpected argument(s): 2"
    end

    test "a group with no subcommand exits 2" do
      result = run("acme pr")
      assert result.exit_code == 2
      assert result.stderr =~ "missing subcommand"
    end
  end

  describe "passthrough flags" do
    defp passthrough_cli do
      CLI.new("acme",
        commands: [
          CLI.command("run",
            doc: "Run on a target, forwarding backend flags",
            args: [%{name: :target, required: true}],
            allow_unknown_flags: true,
            flags: [verbose: [type: :boolean, short: "-v"]],
            run: fn inv ->
              {Command.ok("target=#{hd(inv.args)} extra=#{inspect(inv.extra_flags)}\n"), inv.bash}
            end
          )
        ]
      )
    end

    defp run_pt(script) do
      bash = JustBash.new(commands: %{"acme" => passthrough_cli()})
      {result, _bash} = JustBash.exec(bash, script)
      result
    end

    test "collects undeclared flags into extra_flags, keeping positionals clean" do
      result = run_pt("acme run target --some-dynamic-flag value")
      assert result.exit_code == 0
      assert result.stdout == ~s(target=target extra=["--some-dynamic-flag", "value"]\n)
    end

    test "still parses declared flags normally" do
      result = run_pt("acme run target -v --dyn x")
      assert result.exit_code == 0
      assert result.stdout == ~s(target=target extra=["--dyn", "x"]\n)
    end

    test "an undeclared flag still errors when allow_unknown_flags is not set" do
      result = run("acme pr review --report 1 --bogus x")
      assert result.exit_code == 2
      assert result.stderr =~ "unknown option: --bogus"
    end
  end

  describe "command-level validation" do
    defp validating_cli do
      CLI.new("acme",
        commands: [
          CLI.command("book",
            doc: "Book a range",
            flags: [
              start: [type: :integer, required: true, long: "--start"],
              finish: [type: :integer, required: true, long: "--finish"]
            ],
            validate: fn inv ->
              if inv.flags.start <= inv.flags.finish,
                do: :ok,
                else: {:error, "acme book: --start must be <= --finish"}
            end,
            run: fn inv -> {Command.ok("booked\n"), inv.bash} end
          )
        ]
      )
    end

    defp run_val(script) do
      bash = JustBash.new(commands: %{"acme" => validating_cli()})
      {result, _bash} = JustBash.exec(bash, script)
      result
    end

    test "an :ok validation proceeds to the handler" do
      result = run_val("acme book --start 1 --finish 5")
      assert result.exit_code == 0
      assert result.stdout == "booked\n"
    end

    test "an {:error, msg} validation exits 2 with a usage line" do
      result = run_val("acme book --start 5 --finish 1")
      assert result.exit_code == 2
      assert result.stderr =~ "--start must be <= --finish"
      assert result.stderr =~ "Usage: acme book"
    end

    test "validation runs after defaults are merged" do
      cli =
        CLI.new("acme",
          commands: [
            CLI.command("go",
              flags: [mode: [type: :string, default: "fast"]],
              validate: fn inv ->
                if inv.flags.mode == "fast", do: :ok, else: {:error, "bad mode"}
              end,
              run: fn inv -> {Command.ok("#{inv.flags.mode}\n"), inv.bash} end
            )
          ]
        )

      bash = JustBash.new(commands: %{"acme" => cli})
      {result, _bash} = JustBash.exec(bash, "acme go")
      assert result.exit_code == 0
      assert result.stdout == "fast\n"
    end
  end

  describe "crash isolation" do
    test "a crashing handler is caught and turned into an error" do
      cli =
        CLI.new("boom",
          commands: [CLI.command("go", run: fn _inv -> raise "kaboom" end)]
        )

      bash = JustBash.new(commands: %{"boom" => cli})
      {result, _bash} = JustBash.exec(bash, "boom go")
      assert result.exit_code == 1
      assert result.stderr =~ "boom"
    end

    test "a handler that returns a non-tuple yields a clear, CLI-attributed error" do
      cli =
        CLI.new("boom",
          commands: [CLI.command("bad", run: fn _inv -> :not_a_tuple end)]
        )

      bash = JustBash.new(commands: %{"boom" => cli})
      {result, _bash} = JustBash.exec(bash, "boom bad")
      assert result.exit_code == 1
      assert result.stderr =~ "handler must return {result, bash}"
    end
  end
end
