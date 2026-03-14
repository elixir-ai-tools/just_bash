defmodule JustBash.Commands.CommandTest do
  use ExUnit.Case, async: true

  describe "command -v" do
    test "finds a builtin command" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "command -v echo")
      assert result.exit_code == 0
      assert result.stdout == "echo\n"
    end

    test "finds a command in PATH" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "command -v cat")
      assert result.exit_code == 0
      assert result.stdout == "cat\n"
    end

    test "returns failure for unknown command" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "command -v nonexistent")
      assert result.exit_code == 1
      assert result.stdout == ""
    end

    test "finds a shell function" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        myfunc() { echo hi; }
        command -v myfunc
        """)

      assert result.exit_code == 0
      assert result.stdout == "myfunc\n"
    end

    test "finds a custom command" do
      defmodule TestGreet do
        @behaviour JustBash.Commands.Command
        @impl true
        def names, do: ["testgreet"]
        @impl true
        def execute(bash, _args, _stdin),
          do: {%{stdout: "hi\n", stderr: "", exit_code: 0}, bash}
      end

      bash = JustBash.new(commands: %{"testgreet" => TestGreet})
      {result, _} = JustBash.exec(bash, "command -v testgreet")
      assert result.exit_code == 0
      assert result.stdout == "testgreet\n"
    end

    test "checks multiple commands" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "command -v echo cat nonexistent")
      assert result.exit_code == 1
      assert result.stdout =~ "echo\n"
      assert result.stdout =~ "cat\n"
    end
  end

  describe "command -V" do
    test "describes a builtin" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "command -V echo")
      assert result.exit_code == 0
      assert result.stdout =~ "echo"
      assert result.stdout =~ "builtin"
    end

    test "describes a shell function" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        myfunc() { echo hi; }
        command -V myfunc
        """)

      assert result.exit_code == 0
      assert result.stdout =~ "myfunc"
      assert result.stdout =~ "function"
    end

    test "describes a custom command" do
      defmodule TestGreet2 do
        @behaviour JustBash.Commands.Command
        @impl true
        def names, do: ["testgreet2"]
        @impl true
        def execute(bash, _args, _stdin),
          do: {%{stdout: "hi\n", stderr: "", exit_code: 0}, bash}
      end

      bash = JustBash.new(commands: %{"testgreet2" => TestGreet2})
      {result, _} = JustBash.exec(bash, "command -V testgreet2")
      assert result.exit_code == 0
      assert result.stdout =~ "testgreet2"
    end

    test "reports not found" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "command -V nonexistent")
      assert result.exit_code == 1
      assert result.stderr =~ "not found"
    end
  end

  describe "command (bypass functions)" do
    test "command bypasses shell function" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        echo() { printf "FUNC: %s\\n" "$*"; }
        command echo hello
        """)

      assert result.stdout == "hello\n"
    end

    test "command still executes custom commands" do
      defmodule TestCustom do
        @behaviour JustBash.Commands.Command
        @impl true
        def names, do: ["testcustom"]
        @impl true
        def execute(bash, args, _stdin),
          do: {%{stdout: "custom:#{Enum.join(args, ",")}\n", stderr: "", exit_code: 0}, bash}
      end

      bash = JustBash.new(commands: %{"testcustom" => TestCustom})
      {result, _} = JustBash.exec(bash, "command testcustom a b")
      assert result.stdout == "custom:a,b\n"
    end

    test "command with builtin when no function override" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "command echo hello")
      assert result.stdout == "hello\n"
    end

    test "command returns not found for unknown command" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "command nonexistent")
      assert result.exit_code == 127
      assert result.stderr =~ "not found"
    end
  end
end
