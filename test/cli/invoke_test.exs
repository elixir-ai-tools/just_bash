defmodule JustBash.CLI.InvokeTest do
  use ExUnit.Case, async: true

  alias JustBash.CLI
  alias JustBash.Commands.Command

  defp acme do
    CLI.new("acme",
      commands: [
        CLI.command("pr",
          doc: "PRs",
          commands: [
            CLI.command("review",
              flags: [
                report: [type: :integer, required: true],
                format: [type: :string, default: "text", values: ~w(text json)]
              ],
              run: fn inv ->
                {Command.ok("report=#{inv.flags.report} format=#{inv.flags.format}\n"), inv.bash}
              end
            )
          ]
        )
      ]
    )
  end

  test "invokes a leaf by explicit path and merges flag defaults" do
    bash = JustBash.new()
    {result, _bash} = CLI.invoke(acme(), ["pr", "review"], ["--report", "7"], bash)
    assert result.exit_code == 0
    # `format` came through as its default, not nil — the surprise a hand-built Invocation hits.
    assert result.stdout == "report=7 format=text\n"
  end

  test "surfaces parse errors the same way run/4 does (exit 2 + usage)" do
    bash = JustBash.new()
    {result, _bash} = CLI.invoke(acme(), ["pr", "review"], [], bash)
    assert result.exit_code == 2
    assert result.stderr =~ "missing required flag: --report"
    assert result.stderr =~ "Usage: acme pr review"
  end

  test "raises when the path is not a leaf" do
    bash = JustBash.new()

    assert_raise ArgumentError, ~r/is not a leaf command/, fn ->
      CLI.invoke(acme(), ["pr"], [], bash)
    end
  end
end
