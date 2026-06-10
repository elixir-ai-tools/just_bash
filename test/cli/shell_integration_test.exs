defmodule JustBash.CLI.ShellIntegrationTest do
  use ExUnit.Case, async: true

  alias JustBash.CLI
  alias JustBash.Commands.Command

  defp acme do
    CLI.new("acme",
      doc: "Acme operations toolkit",
      commands: [
        CLI.command("pr",
          doc: "PRs",
          commands: [
            CLI.command("review", run: fn inv -> {Command.ok("r\n"), inv.bash} end),
            CLI.command("open", run: fn inv -> {Command.ok("o\n"), inv.bash} end)
          ]
        ),
        CLI.command("whoami", run: fn inv -> {Command.ok("w\n"), inv.bash} end)
      ]
    )
  end

  defmodule Greet do
    @behaviour Command
    @impl true
    def names, do: ["greet"]
    @impl true
    def execute(bash, _args, _stdin), do: {Command.ok("hi\n"), bash}
  end

  defp run(script) do
    bash = JustBash.new(commands: %{"acme" => acme(), "greet" => Greet})
    {result, _bash} = JustBash.exec(bash, script)
    result
  end

  describe "type" do
    test "describes a CLI tool with its subcommand count" do
      result = run("type acme")
      assert result.stdout == "acme is a CLI tool (3 commands)\n"
    end

    test "still describes a plain command module the terse way" do
      assert run("type greet").stdout == "greet is greet\n"
    end
  end

  describe "command -V" do
    test "describes a CLI tool" do
      assert run("command -V acme").stdout == "acme is a CLI tool (3 commands)\n"
    end
  end

  def handle_event(_event, _measure, meta, {ref, pid}), do: send(pid, {ref, meta})

  describe "telemetry" do
    setup do
      ref = make_ref()
      handler_id = "cli-subcommand-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:just_bash, :command, :stop],
        &__MODULE__.handle_event/4,
        {ref, self()}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      %{ref: ref}
    end

    test "includes the resolved subcommand path in command telemetry", %{ref: ref} do
      run("acme pr review")
      assert_received {^ref, %{command: "acme", subcommand: ["pr", "review"]}}
    end

    test "non-CLI commands carry no subcommand key", %{ref: ref} do
      run("greet")
      assert_received {^ref, %{command: "greet"} = meta}
      refute Map.has_key?(meta, :subcommand)
    end

    test "the subcommand key never leaks into command output" do
      result = run("acme pr review")
      assert result.stdout == "r\n"
      refute Map.has_key?(result, :__subcommand__)
    end
  end
end
