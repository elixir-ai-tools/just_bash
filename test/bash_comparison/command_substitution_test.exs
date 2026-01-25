defmodule JustBash.BashComparison.CommandSubstitutionTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "command substitution comparison" do
    test "simple command" do
      compare_bash("echo $(echo hello)")
    end

    test "nested command substitution" do
      compare_bash("echo $(echo $(echo nested))")
    end

    test "with arithmetic" do
      compare_bash("echo $(echo $((1 + 2)))")
    end

    test "backtick style" do
      compare_bash("echo `echo hello`")
    end
  end

  describe "command substitution with pipes" do
    test "pipe in command substitution" do
      compare_bash("echo $(echo hello | cat)")
    end

    test "pipe in quoted command substitution" do
      compare_bash("echo \"$(echo hello | cat)\"")
    end

    test "command substitution with pipe as argument" do
      compare_bash("x=\"$(echo test | cat)\"; echo \"[$x]\"")
    end

    test "command substitution with pipe directly in test -z" do
      compare_bash("[ -z \"$(echo hello | cat)\" ] && echo empty || echo notempty")
    end

    test "command substitution with multiple pipes" do
      compare_bash("echo \"$(echo hello | cat | cat)\"")
    end

    test "command substitution preserves multiline output" do
      compare_bash("echo \"$(echo -e 'a\\nb\\nc' | cat)\"")
    end
  end

  describe "command substitution with nested quotes" do
    test "quoted command substitution with inner double quotes" do
      compare_bash("echo \"$(echo 'test')\"")
    end

    test "quoted command substitution with grep pattern" do
      compare_bash("echo \"$(echo hello | grep 'hello')\"")
    end

    test "quoted command substitution with inner escaped quotes" do
      # This is the failing case: "$(cmd "arg")"
      bash = JustBash.new(files: %{"/test.txt" => "hello world"})
      script = "echo \"$(cat /test.txt | grep \"hello\")\""
      {result, _} = JustBash.exec(bash, script)
      assert result.stdout == "hello world\n"
    end
  end
end
