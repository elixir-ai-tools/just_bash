defmodule JustBash.CLI.AuthorizationTest do
  use ExUnit.Case, async: true

  alias JustBash.CLI
  alias JustBash.Commands.Command

  # `admin` group is present only when bash.context.admin is true. `whoami` is always present.
  defp acme do
    CLI.new("acme",
      doc: "Acme toolkit",
      commands: [
        CLI.command("whoami",
          doc: "Print the current user",
          run: fn inv -> {Command.ok("#{inv.bash.context.user}\n"), inv.bash} end
        ),
        CLI.command("admin",
          doc: "Privileged operations",
          visible?: fn bash -> bash.context[:admin] == true end,
          commands: [
            CLI.command("rotate",
              doc: "Rotate secrets",
              run: fn inv -> {Command.ok("rotated\n"), inv.bash} end
            )
          ]
        )
      ]
    )
  end

  defp run(script, context) do
    bash = JustBash.new(commands: %{"acme" => acme()}, context: context)
    {result, _bash} = JustBash.exec(bash, script)
    result
  end

  describe "routing under a visibility predicate" do
    test "a hidden subtree is routable for an authorized caller" do
      result = run("acme admin rotate", %{user: "dave", admin: true})
      assert result.exit_code == 0
      assert result.stdout == "rotated\n"
    end

    test "a hidden subtree is genuinely absent (unknown command) for an unauthorized caller" do
      result = run("acme admin rotate", %{user: "dave", admin: false})
      assert result.exit_code == 2
      assert result.stderr =~ "unknown command 'admin'"
    end

    test "always-visible commands work regardless of context" do
      assert run("acme whoami", %{user: "dave", admin: false}).stdout == "dave\n"
    end
  end

  describe "help reflects visibility" do
    test "an unauthorized caller does not see the hidden group in --help" do
      result = run("acme --help", %{user: "dave", admin: false})
      assert result.stdout =~ "whoami"
      refute result.stdout =~ "admin"
    end

    test "an authorized caller sees the hidden group in --help" do
      result = run("acme --help", %{user: "dave", admin: true})
      assert result.stdout =~ "admin"
    end
  end

  describe "describe/2 reflects visibility" do
    test "filters by the given caller's context" do
      bash_user = JustBash.new(context: %{user: "dave", admin: false})
      bash_admin = JustBash.new(context: %{user: "dave", admin: true})

      user_paths = CLI.describe(acme(), bash_user).commands |> Enum.map(& &1.path)
      admin_paths = CLI.describe(acme(), bash_admin).commands |> Enum.map(& &1.path)

      refute ["admin", "rotate"] in user_paths
      assert ["admin", "rotate"] in admin_paths
    end

    test "describe/1 with no bash shows every command" do
      paths = CLI.describe(acme()).commands |> Enum.map(& &1.path)
      assert ["admin", "rotate"] in paths
      assert ["whoami"] in paths
    end
  end
end
