defmodule JustBash.CLI.HelpTest do
  use ExUnit.Case, async: true

  alias JustBash.CLI
  alias JustBash.Commands.Command

  defp acme do
    CLI.new("acme",
      doc: "Acme operations toolkit",
      commands: [
        CLI.command("pr",
          doc: "Pull request management",
          commands: [
            CLI.command("review",
              doc: "Review a pull request",
              flags: [
                report: [type: :integer, required: true, doc: "ID of the report to review"],
                format: [
                  type: :string,
                  default: "text",
                  values: ~w(text json),
                  doc: "Output format"
                ],
                verbose: [type: :boolean, short: "-v", doc: "Verbose output"]
              ],
              run: fn inv -> {Command.ok("ok\n"), inv.bash} end
            ),
            CLI.command("open",
              doc: "Open a pull request",
              args: [%{name: :id, required: true, doc: "PR id"}],
              run: fn inv -> {Command.ok("ok\n"), inv.bash} end
            )
          ]
        ),
        CLI.command("whoami", doc: "Print user", run: fn inv -> {Command.ok("u\n"), inv.bash} end)
      ]
    )
  end

  defp run(script) do
    {result, _bash} = JustBash.exec(JustBash.new(commands: %{"acme" => acme()}), script)
    result
  end

  describe "root --help" do
    test "lists top-level commands and exits 0" do
      result = run("acme --help")
      assert result.exit_code == 0
      assert result.stdout =~ "acme - Acme operations toolkit"
      assert result.stdout =~ "Usage: acme <command> [args]"
      assert result.stdout =~ "Commands:"
      assert result.stdout =~ "pr"
      assert result.stdout =~ "whoami"
      assert result.stdout =~ "Pull request management (group)"
      assert result.stdout =~ "Run 'acme <command> --help'"
    end

    test "-h is an alias for --help" do
      assert run("acme -h").stdout =~ "Usage: acme <command> [args]"
    end

    test "a group with no subcommand shows its commands and exits 2" do
      result = run("acme pr")
      assert result.exit_code == 2
      assert result.stderr =~ "acme pr: missing subcommand"
      assert result.stderr =~ "review"
      assert result.stderr =~ "open"
    end
  end

  describe "group --help" do
    test "lists the group's children" do
      result = run("acme pr --help")
      assert result.exit_code == 0
      assert result.stdout =~ "acme pr - Pull request management"
      assert result.stdout =~ "Usage: acme pr <command> [args]"
      assert result.stdout =~ "review"
      assert result.stdout =~ "Review a pull request"
    end
  end

  describe "leaf --help" do
    test "shows a usage line with required and optional flags" do
      result = run("acme pr review --help")
      assert result.exit_code == 0
      assert result.stdout =~ "acme pr review - Review a pull request"

      assert result.stdout =~
               "Usage: acme pr review --report <int> [--format text|json] [-v]"
    end

    test "documents each flag with annotations" do
      result = run("acme pr review --help")
      assert result.stdout =~ "Options:"
      assert result.stdout =~ "--report <int>"
      assert result.stdout =~ "ID of the report to review (required)"
      assert result.stdout =~ "(values: text, json)"
      assert result.stdout =~ "(default: text)"
      assert result.stdout =~ "-v, --verbose"
    end

    test "documents positional arguments" do
      result = run("acme pr open --help")
      assert result.stdout =~ "Usage: acme pr open <id>"
      assert result.stdout =~ "Arguments:"
      assert result.stdout =~ "<id>"
      assert result.stdout =~ "PR id (required)"
    end
  end

  describe "errors carry usage and suggestions" do
    test "unknown subcommand suggests the closest match" do
      result = run("acme pr reviw --report 1")
      assert result.exit_code == 2
      assert result.stderr =~ "unknown command 'pr reviw'"
      assert result.stderr =~ "Did you mean 'pr review'?"
    end

    test "an unrelated unknown subcommand offers no suggestion" do
      result = run("acme pr zzzzzzz")
      assert result.exit_code == 2
      assert result.stderr =~ "unknown command 'pr zzzzzzz'"
      refute result.stderr =~ "Did you mean"
    end

    test "missing required flag includes the usage line" do
      result = run("acme pr review")
      assert result.exit_code == 2
      assert result.stderr =~ "missing required flag: --report"
      assert result.stderr =~ "Usage: acme pr review --report <int>"
    end
  end
end
