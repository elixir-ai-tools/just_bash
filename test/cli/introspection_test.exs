defmodule JustBash.CLI.IntrospectionTest do
  use ExUnit.Case, async: true

  alias JustBash.CLI
  alias JustBash.Commands.Command

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
                format: [type: :string, default: "text", values: ~w(text json), doc: "Format"]
              ],
              run: fn inv -> {Command.ok(), inv.bash} end
            ),
            CLI.command("open",
              doc: "Open a PR",
              args: [%{name: :id, required: true, doc: "PR id"}],
              run: fn inv -> {Command.ok(), inv.bash} end
            )
          ]
        ),
        CLI.command("whoami", doc: "Print user", run: fn inv -> {Command.ok(), inv.bash} end)
      ]
    )
  end

  describe "describe/1" do
    test "returns the tool metadata" do
      desc = CLI.describe(acme())
      assert desc.name == "acme"
      assert desc.doc == "Acme operations toolkit"
      assert desc.aliases == ["ac"]
    end

    test "flattens leaves with full invocation paths" do
      paths = CLI.describe(acme()).commands |> Enum.map(& &1.path)
      assert paths == [["pr", "review"], ["pr", "open"], ["whoami"]]
    end

    test "resolves flag specs into plain maps with derived long forms" do
      review = CLI.describe(acme()).commands |> Enum.find(&(&1.path == ["pr", "review"]))
      report = Enum.find(review.flags, &(&1.name == :report))

      assert report.type == :integer
      assert report.required == true
      assert report.long == "--report"

      format = Enum.find(review.flags, &(&1.name == :format))
      assert format.default == "text"
      assert format.values == ["text", "json"]
    end

    test "includes positional argument specs" do
      open = CLI.describe(acme()).commands |> Enum.find(&(&1.path == ["pr", "open"]))
      assert [%{name: :id, required: true}] = open.args
    end
  end

  describe "render_docs/2" do
    test "defaults to text and includes commands and usage" do
      text = CLI.render_docs(acme())
      assert text =~ "acme - Acme operations toolkit"
      assert text =~ "Usage: acme pr review --report <int>"
      assert text =~ "Usage: acme pr open <id>"
    end

    test "markdown format produces tables" do
      md = CLI.render_docs(acme(), format: :markdown)
      assert md =~ "# acme"
      assert md =~ "## acme pr review"
      assert md =~ "```\nUsage: acme pr review --report <int> [--format text|json]\n```"
      assert md =~ "| Flag | Type | Required | Default | Description |"
      assert md =~ "| `--report` | integer | yes |  | Report ID |"
      assert md =~ "## acme pr open"
      assert md =~ "| Argument | Required | Description |"
      assert md =~ "| `id` | yes | PR id |"
    end
  end
end
