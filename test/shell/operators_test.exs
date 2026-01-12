defmodule JustBash.Shell.OperatorsTest do
  use ExUnit.Case, async: true

  describe "operators" do
    test "! negates exit code" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "! false")
      assert result.exit_code == 0

      {result2, _} = JustBash.exec(bash, "! true")
      assert result2.exit_code == 1
    end

    test "&& runs second command only if first succeeds" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "true && echo yes")
      assert result.stdout == "yes\n"

      {result2, _} = JustBash.exec(bash, "false && echo no")
      assert result2.stdout == ""
    end

    test "|| runs second command only if first fails" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "false || echo yes")
      assert result.stdout == "yes\n"

      {result2, _} = JustBash.exec(bash, "true || echo no")
      assert result2.stdout == ""
    end

    test "combined && and || operators" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "true && echo a || echo b")
      assert result.stdout == "a\n"

      {result2, _} = JustBash.exec(bash, "false && echo a || echo b")
      assert result2.stdout == "b\n"
    end
  end

  describe "pipes" do
    test "simple pipe" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo hello | cat")
      assert result.stdout == "hello\n"
    end

    test "multiple pipes" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'c\na\nb' | sort | head -1")
      assert result.stdout == "a\n"
    end

    test "pipe with grep" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo -e 'apple\\nbanana\\napricot' | grep ap")
      assert result.stdout == "apple\napricot\n"
    end

    test "pipe with wc" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo -e 'a b c' | wc -w")
      assert String.trim(result.stdout) == "3"
    end

    test "pipe with multiple commands" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "seq 10 | head -5 | tail -2")
      assert result.stdout == "4\n5\n"
    end
  end

  describe "command sequences" do
    test "semicolon runs commands sequentially" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo a; echo b; echo c")
      assert result.stdout == "a\nb\nc\n"
    end

    test "semicolon continues after failure" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "false; echo continued")
      assert result.stdout == "continued\n"
    end

    test "newline separates commands" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        echo first
        echo second
        echo third
        """)

      assert result.stdout == "first\nsecond\nthird\n"
    end
  end
end
