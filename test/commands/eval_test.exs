defmodule JustBash.Commands.EvalTest do
  use ExUnit.Case, async: true

  describe "eval" do
    test "eval executes a simple command" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "eval echo hello")
      assert result.stdout == "hello\n"
    end

    test "eval joins all arguments into a single string" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "eval echo hello world")
      assert result.stdout == "hello world\n"
    end

    test "eval with no arguments succeeds" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "eval")
      assert result.exit_code == 0
      assert result.stdout == ""
    end

    test "eval runs in the current shell (variable assignment persists)" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        eval 'x=42'
        echo $x
        """)

      assert result.stdout == "42\n"
    end

    test "eval with variable expansion" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        cmd="echo hello"
        eval $cmd
        """)

      assert result.stdout == "hello\n"
    end

    test "eval with double expansion" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        var=hello
        ref='$var'
        eval echo $ref
        """)

      assert result.stdout == "hello\n"
    end

    test "eval with quoted strings containing special chars" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        eval 'echo "hello; world"'
        """)

      assert result.stdout == "hello; world\n"
    end

    test "eval can define functions" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        eval 'greet() { echo "Hi $1"; }'
        greet Alice
        """)

      assert result.stdout == "Hi Alice\n"
    end

    test "eval returns exit code of executed command" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "eval false")
      assert result.exit_code == 1
    end

    test "eval with syntax error" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "eval 'echo \"unterminated'")
      assert result.exit_code != 0
      assert result.stderr =~ "syntax error"
    end

    test "eval with custom commands" do
      defmodule TestCmd do
        @behaviour JustBash.Commands.Command
        @impl true
        def names, do: ["testcmd"]
        @impl true
        def execute(bash, args, _stdin) do
          {%{stdout: "custom:#{Enum.join(args, ",")}\n", stderr: "", exit_code: 0}, bash}
        end
      end

      bash = JustBash.new(commands: %{"testcmd" => TestCmd})
      {result, _} = JustBash.exec(bash, "eval testcmd a b c")
      assert result.stdout == "custom:a,b,c\n"
    end

    test "eval with pipeline" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "eval 'echo hello world | tr h H'")
      assert result.stdout == "Hello world\n"
    end
  end
end
