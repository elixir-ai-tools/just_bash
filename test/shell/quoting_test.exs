defmodule JustBash.Shell.QuotingTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for shell quoting behavior.

  Key rules:
  - Single quotes preserve everything literally (no expansion)
  - Double quotes allow expansion but preserve most characters
  - Single quotes INSIDE double quotes are just literal characters
  - Backslash escapes work in double quotes
  """

  describe "single quotes inside double quotes" do
    test "single quote is preserved as literal character" do
      bash = JustBash.new()
      # X="it's" - single quote inside double quotes is literal
      {result, _} = JustBash.exec(bash, "X=\"it's\"; echo \"$X\"")
      assert result.stdout == "it's\n"
    end

    test "multiple single quotes preserved" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "X=\"'a' 'b' 'c'\"; echo \"$X\"")
      assert result.stdout == "'a' 'b' 'c'\n"
    end

    test "SQL-style single quotes in value" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "X=\"VALUES ('hello')\"; echo \"$X\"")
      assert result.stdout == "VALUES ('hello')\n"
    end

    test "single quote at start of double-quoted string" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "X=\"'start\"; echo \"$X\"")
      assert result.stdout == "'start\n"
    end

    test "single quote at end of double-quoted string" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "X=\"end'\"; echo \"$X\"")
      assert result.stdout == "end'\n"
    end

    test "empty single quotes inside double quotes" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "X=\"before '' after\"; echo \"$X\"")
      assert result.stdout == "before '' after\n"
    end

    test "nested quotes in SQL INSERT" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, "X=\"INSERT INTO t VALUES ('name', 'value')\"; echo \"$X\"")

      assert result.stdout == "INSERT INTO t VALUES ('name', 'value')\n"
    end
  end

  describe "single quote only strings" do
    test "single quotes prevent all expansion" do
      bash = JustBash.new(env: %{"VAR" => "value"})
      {result, _} = JustBash.exec(bash, "echo '$VAR'")
      assert result.stdout == "$VAR\n"
    end

    test "single quotes prevent command substitution" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo '$(echo hello)'")
      assert result.stdout == "$(echo hello)\n"
    end

    test "double quote inside single quotes is literal" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'say \"hello\"'")
      assert result.stdout == "say \"hello\"\n"
    end
  end

  describe "double quotes" do
    test "double quotes allow variable expansion" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "X=world; echo \"hello $X\"")
      assert result.stdout == "hello world\n"
    end

    test "double quotes allow command substitution" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo \"result: $(echo 42)\"")
      assert result.stdout == "result: 42\n"
    end

    test "double quotes preserve spaces" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "X=\"a   b   c\"; echo \"$X\"")
      assert result.stdout == "a   b   c\n"
    end

    test "backslash-dollar is literal dollar" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo \"cost: \\$100\"")
      assert result.stdout == "cost: $100\n"
    end

    test "backslash-doublequote is literal doublequote" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo \"say \\\"hello\\\"\"")
      assert result.stdout == "say \"hello\"\n"
    end
  end

  describe "assignment preserves quotes in value" do
    test "assignment strips outer quotes only" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "X=\"hello\"")
      assert bash.env["X"] == "hello"
    end

    test "single quotes in value are preserved in env" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "X=\"it's\"")
      assert bash.env["X"] == "it's"
    end

    test "SQL string stored correctly" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "X=\"VALUES ('test')\"")
      assert bash.env["X"] == "VALUES ('test')"
    end

    test "multiple SQL values stored correctly" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "X=\"INSERT INTO t VALUES ('a', 'b')\"")
      assert bash.env["X"] == "INSERT INTO t VALUES ('a', 'b')"
    end
  end

  describe "building strings incrementally" do
    test "appending to SQL string preserves quotes" do
      bash = JustBash.new()

      {_, bash} = JustBash.exec(bash, "SQL=\"CREATE TABLE t (n INT);\"")
      assert bash.env["SQL"] == "CREATE TABLE t (n INT);"

      {_, bash} = JustBash.exec(bash, "SQL=\"$SQL INSERT INTO t VALUES (1);\"")
      assert bash.env["SQL"] == "CREATE TABLE t (n INT); INSERT INTO t VALUES (1);"
    end

    test "appending SQL with quoted strings" do
      bash = JustBash.new()

      {_, bash} = JustBash.exec(bash, "SQL=\"INSERT INTO t VALUES ('hello');\"")
      {_, bash} = JustBash.exec(bash, "SQL=\"$SQL INSERT INTO t VALUES ('world');\"")

      assert bash.env["SQL"] == "INSERT INTO t VALUES ('hello'); INSERT INTO t VALUES ('world');"
    end
  end

  describe "edge cases" do
    test "empty string in double quotes" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "X=\"\"")
      assert bash.env["X"] == ""
    end

    test "empty string in single quotes" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "X=''")
      assert bash.env["X"] == ""
    end

    test "only a single quote character" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "X=\"'\"")
      assert bash.env["X"] == "'"
    end
  end
end
