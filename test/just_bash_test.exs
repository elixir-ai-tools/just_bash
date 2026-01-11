defmodule JustBashTest do
  use ExUnit.Case
  doctest JustBash

  describe "tokenize/1" do
    test "tokenizes simple command" do
      tokens = JustBash.tokenize("echo hello")
      assert length(tokens) == 3
      assert Enum.at(tokens, 0).type == :name
      assert Enum.at(tokens, 0).value == "echo"
      assert Enum.at(tokens, 1).type == :name
      assert Enum.at(tokens, 1).value == "hello"
      assert Enum.at(tokens, 2).type == :eof
    end

    test "tokenizes operators" do
      tokens = JustBash.tokenize("a && b || c")
      types = Enum.map(tokens, & &1.type)
      assert :and_and in types
      assert :or_or in types
    end

    test "tokenizes pipe" do
      tokens = JustBash.tokenize("ls | grep foo")
      types = Enum.map(tokens, & &1.type)
      assert :pipe in types
    end

    test "tokenizes redirections" do
      tokens = JustBash.tokenize("echo hello > file.txt")
      types = Enum.map(tokens, & &1.type)
      assert :great in types
    end

    test "tokenizes assignment" do
      tokens = JustBash.tokenize("VAR=value")
      assert Enum.at(tokens, 0).type == :assignment_word
      assert Enum.at(tokens, 0).value == "VAR=value"
    end

    test "tokenizes reserved words" do
      tokens = JustBash.tokenize("if then else fi")
      types = Enum.map(tokens, & &1.type)
      assert :if in types
      assert :then in types
      assert :else in types
      assert :fi in types
    end
  end

  describe "parse/1" do
    test "parses simple command" do
      {:ok, ast} = JustBash.parse("echo hello")
      assert %JustBash.AST.Script{} = ast
      assert length(ast.statements) == 1
    end

    test "parses pipeline" do
      {:ok, ast} = JustBash.parse("ls | grep foo")
      [stmt] = ast.statements
      [pipeline] = stmt.pipelines
      assert length(pipeline.commands) == 2
    end

    test "parses if statement" do
      {:ok, ast} = JustBash.parse("if true; then echo yes; fi")
      [stmt] = ast.statements
      [pipeline] = stmt.pipelines
      [cmd] = pipeline.commands
      assert %JustBash.AST.If{} = cmd
    end

    test "parses for loop" do
      {:ok, ast} = JustBash.parse("for i in a b c; do echo $i; done")
      [stmt] = ast.statements
      [pipeline] = stmt.pipelines
      [cmd] = pipeline.commands
      assert %JustBash.AST.For{} = cmd
      assert cmd.variable == "i"
    end

    test "parses while loop" do
      {:ok, ast} = JustBash.parse("while true; do echo loop; done")
      [stmt] = ast.statements
      [pipeline] = stmt.pipelines
      [cmd] = pipeline.commands
      assert %JustBash.AST.While{} = cmd
    end

    test "parses case statement" do
      {:ok, ast} = JustBash.parse("case x in a) echo a;; b) echo b;; esac")
      [stmt] = ast.statements
      [pipeline] = stmt.pipelines
      [cmd] = pipeline.commands
      assert %JustBash.AST.Case{} = cmd
    end

    test "parses function definition" do
      {:ok, ast} = JustBash.parse("foo() { echo bar; }")
      [stmt] = ast.statements
      [pipeline] = stmt.pipelines
      [cmd] = pipeline.commands
      assert %JustBash.AST.FunctionDef{} = cmd
      assert cmd.name == "foo"
    end

    test "returns error for invalid syntax" do
      {:error, error} = JustBash.parse("if then")
      assert error.message =~ "Expected"
    end
  end

  describe "exec/2" do
    test "executes echo command" do
      bash = JustBash.new()
      {result, _bash} = JustBash.exec(bash, "echo hello world")
      assert result.stdout == "hello world\n"
      assert result.exit_code == 0
    end

    test "executes true command" do
      bash = JustBash.new()
      {result, _bash} = JustBash.exec(bash, "true")
      assert result.exit_code == 0
    end

    test "executes false command" do
      bash = JustBash.new()
      {result, _bash} = JustBash.exec(bash, "false")
      assert result.exit_code == 1
    end

    test "executes pwd command" do
      bash = JustBash.new()
      {result, _bash} = JustBash.exec(bash, "pwd")
      assert result.stdout == "/home/user\n"
    end

    test "returns error for unknown command" do
      bash = JustBash.new()
      {result, _bash} = JustBash.exec(bash, "nonexistent")
      assert result.exit_code == 127
      assert result.stderr =~ "command not found"
    end

    test "handles syntax errors" do
      bash = JustBash.new()
      {result, _bash} = JustBash.exec(bash, "if then")
      assert result.exit_code == 2
      assert result.stderr =~ "syntax error"
    end
  end
end
