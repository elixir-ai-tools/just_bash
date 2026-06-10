defmodule JustBash.CLI.UseMacroTest do
  use ExUnit.Case, async: true

  alias JustBash.CLI
  alias JustBash.Commands.Command

  defmodule AcmeCLI do
    use JustBash.CLI

    @impl true
    def spec do
      CLI.new("acme",
        doc: "Acme operations toolkit",
        aliases: ["ac"],
        commands: [
          CLI.command("greet",
            doc: "Greet someone",
            args: [%{name: :who, required: true}],
            run: fn inv -> {Command.ok("hi #{Enum.join(inv.args, " ")}\n"), inv.bash} end
          )
        ]
      )
    end
  end

  test "a use-module is a valid Command" do
    assert function_exported?(AcmeCLI, :names, 0)
    assert function_exported?(AcmeCLI, :execute, 3)
    assert AcmeCLI.names() == ["acme", "ac"]
  end

  test "registers and dispatches by module name" do
    bash = JustBash.new(commands: %{"acme" => AcmeCLI})
    {result, _bash} = JustBash.exec(bash, "acme greet world")
    assert result.stdout == "hi world\n"
  end

  test "registers under an alias" do
    bash = JustBash.new(commands: %{"ac" => AcmeCLI})
    {result, _bash} = JustBash.exec(bash, "ac greet there")
    assert result.stdout == "hi there\n"
  end

  test "dispatches identically to a struct-registered CLI" do
    struct_bash = JustBash.new(commands: %{"acme" => AcmeCLI.spec()})
    module_bash = JustBash.new(commands: %{"acme" => AcmeCLI})

    {r1, _} = JustBash.exec(struct_bash, "acme greet x")
    {r2, _} = JustBash.exec(module_bash, "acme greet x")
    assert r1.stdout == r2.stdout
  end

  test "help works through a use-module" do
    bash = JustBash.new(commands: %{"acme" => AcmeCLI})
    {result, _bash} = JustBash.exec(bash, "acme --help")
    assert result.stdout =~ "acme - Acme operations toolkit"
    assert result.stdout =~ "greet"
  end

  describe "cli?/1 and cli_module?/1" do
    test "detects a use-module" do
      assert CLI.cli_module?(AcmeCLI)
      assert CLI.cli?(AcmeCLI)
    end

    test "detects a struct" do
      assert CLI.cli?(AcmeCLI.spec())
    end

    test "rejects non-CLI modules and values" do
      refute CLI.cli_module?(Enum)
      refute CLI.cli?(Enum)
      refute CLI.cli?("acme")
      refute CLI.cli?(%{})
    end
  end

  test "describe/1 and render_docs/2 accept a use-module" do
    assert CLI.describe(AcmeCLI).name == "acme"
    assert CLI.render_docs(AcmeCLI, format: :markdown) =~ "# acme"
  end
end
