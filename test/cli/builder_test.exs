defmodule JustBash.CLI.BuilderTest do
  use ExUnit.Case, async: true

  alias JustBash.CLI
  alias JustBash.CLI.Command

  describe "command/2" do
    test "builds a leaf with a run handler" do
      run = fn inv -> {%{stdout: "", stderr: "", exit_code: 0}, inv.bash} end
      cmd = CLI.command("list", doc: "List things", run: run)

      assert %Command{name: "list", doc: "List things", run: ^run, commands: []} = cmd
      assert Command.leaf?(cmd)
      refute Command.group?(cmd)
    end

    test "builds a group with nested commands" do
      child = CLI.command("review", run: fn inv -> {ok(), inv.bash} end)
      group = CLI.command("pr", doc: "PRs", commands: [child])

      assert %Command{name: "pr", commands: [^child], run: nil} = group
      assert Command.group?(group)
      refute Command.leaf?(group)
    end

    test "normalizes positional arg specs with defaults" do
      cmd =
        CLI.command("show", args: [%{name: :id, required: true}], run: fn i -> {ok(), i.bash} end)

      assert [%{name: :id, required: true, variadic: false, doc: nil}] = cmd.args
    end

    test "raises when a node is neither group nor leaf" do
      assert_raise ArgumentError, ~r/either a group .* or a leaf/, fn ->
        CLI.command("oops")
      end
    end

    test "raises when a node is both group and leaf" do
      child = CLI.command("x", run: fn i -> {ok(), i.bash} end)

      assert_raise ArgumentError, ~r/cannot be both/, fn ->
        CLI.command("pr", commands: [child], run: fn i -> {ok(), i.bash} end)
      end
    end

    test "raises on a non-1-arity run handler" do
      assert_raise ArgumentError, ~r/:run must be a 1-arity function/, fn ->
        CLI.command("x", run: fn _a, _b -> :nope end)
      end
    end

    test "raises on duplicate child names" do
      a = CLI.command("dup", run: fn i -> {ok(), i.bash} end)
      b = CLI.command("dup", run: fn i -> {ok(), i.bash} end)

      assert_raise ArgumentError, ~r/duplicate subcommand name/, fn ->
        CLI.command("group", commands: [a, b])
      end
    end

    test "raises on a name with spaces" do
      assert_raise ArgumentError, ~r/must not contain spaces/, fn ->
        CLI.command("pr review", run: fn i -> {ok(), i.bash} end)
      end
    end

    test "raises on a variadic arg that is not last" do
      assert_raise ArgumentError, ~r/variadic positional argument must be last/, fn ->
        CLI.command("x",
          args: [%{name: :rest, variadic: true}, %{name: :tail}],
          run: fn i -> {ok(), i.bash} end
        )
      end
    end

    test "raises when a required positional follows an optional one" do
      assert_raise ArgumentError,
                   ~r/required positional argument .* cannot follow an optional/,
                   fn ->
                     CLI.command("x",
                       args: [%{name: :a}, %{name: :b, required: true}],
                       run: fn i -> {ok(), i.bash} end
                     )
                   end
    end

    test "allows required positionals before optional ones" do
      cmd =
        CLI.command("x",
          args: [%{name: :a, required: true}, %{name: :b}],
          run: fn i -> {ok(), i.bash} end
        )

      assert [%{name: :a, required: true}, %{name: :b, required: false}] = cmd.args
    end

    test "raises when a flag declares both :required and :default" do
      assert_raise ArgumentError, ~r/cannot be both :required and have a :default/, fn ->
        CLI.command("x",
          flags: [n: [type: :integer, required: true, default: 1]],
          run: fn i -> {ok(), i.bash} end
        )
      end
    end

    test "raises when a flag :default is not a member of :values" do
      assert_raise ArgumentError, ~r/:default "xml" is not one of :values/, fn ->
        CLI.command("x",
          flags: [format: [type: :string, default: "xml", values: ~w(text json)]],
          run: fn i -> {ok(), i.bash} end
        )
      end
    end

    test "allows a flag :default that is a member of :values" do
      cmd =
        CLI.command("x",
          flags: [format: [type: :string, default: "text", values: ~w(text json)]],
          run: fn i -> {ok(), i.bash} end
        )

      assert cmd.flags[:format][:default] == "text"
    end

    test "raises when a flag claims the reserved --help long form" do
      assert_raise ArgumentError, ~r/--help.* is reserved/, fn ->
        CLI.command("x",
          flags: [help: [type: :boolean]],
          run: fn i -> {ok(), i.bash} end
        )
      end
    end

    test "raises when a flag claims the reserved -h short form" do
      assert_raise ArgumentError, ~r/-h.* is reserved/, fn ->
        CLI.command("x",
          flags: [height: [type: :integer, short: "-h"]],
          run: fn i -> {ok(), i.bash} end
        )
      end
    end

    test "raises on flags that are not a keyword list" do
      assert_raise ArgumentError, ~r/:flags must be a keyword list/, fn ->
        CLI.command("x", flags: %{not: :keyword}, run: fn i -> {ok(), i.bash} end)
      end
    end

    test "raises when a group node is given flags" do
      child = CLI.command("review", run: fn i -> {ok(), i.bash} end)

      assert_raise ArgumentError, ~r/group .* cannot define :flags or :args/, fn ->
        CLI.command("pr", commands: [child], flags: [verbose: [type: :boolean]])
      end
    end

    test "raises when a group node is given positional args" do
      child = CLI.command("review", run: fn i -> {ok(), i.bash} end)

      assert_raise ArgumentError, ~r/group .* cannot define :flags or :args/, fn ->
        CLI.command("pr", commands: [child], args: [%{name: :id}])
      end
    end
  end

  describe "new/2" do
    test "builds a CLI root" do
      cmd = CLI.command("list", run: fn i -> {ok(), i.bash} end)
      cli = CLI.new("acme", doc: "Acme toolkit", commands: [cmd], aliases: ["ac"])

      assert %CLI{name: "acme", doc: "Acme toolkit", commands: [^cmd], aliases: ["ac"]} = cli
    end

    test "defaults to no commands and no aliases" do
      assert %CLI{commands: [], aliases: []} = CLI.new("acme")
    end

    test "raises on an empty name" do
      assert_raise ArgumentError, ~r/non-empty string/, fn -> CLI.new("") end
    end

    test "raises on colliding top-level command names" do
      a = CLI.command("dup", run: fn i -> {ok(), i.bash} end)
      b = CLI.command("dup", run: fn i -> {ok(), i.bash} end)

      assert_raise ArgumentError, ~r/duplicate subcommand name/, fn ->
        CLI.new("acme", commands: [a, b])
      end
    end
  end

  defp ok, do: %{stdout: "", stderr: "", exit_code: 0}
end
