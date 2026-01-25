defmodule JustBash.BashComparison.ErrorOutputTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "error output comparison" do
    test "command not found exit code" do
      compare_bash("nonexistent_cmd_xyz 2>/dev/null; echo $?", ignore_exit: true)
    end

    test "cat nonexistent file" do
      # Just check exit code, error message format may differ
      compare_bash("cat /nonexistent_file_xyz 2>/dev/null; echo $?", ignore_exit: true)
    end
  end

  describe "exit code handling" do
    test "false command" do
      compare_bash("false; echo $?")
    end

    test "true command" do
      compare_bash("true; echo $?")
    end

    test "negated true" do
      compare_bash("! true; echo $?")
    end

    test "negated false" do
      compare_bash("! false; echo $?")
    end

    test "subshell exit" do
      compare_bash("(exit 42); echo $?")
    end

    test "subshell exit zero" do
      compare_bash("(exit 0); echo $?")
    end

    test "pipeline exit code is last command" do
      compare_bash("true | false; echo $?")
    end

    test "pipeline exit code with true last" do
      compare_bash("false | true; echo $?")
    end

    test "command chain with semicolon" do
      compare_bash("false; true; echo $?")
    end

    test "test command exit codes" do
      compare_bash("[ 1 -eq 1 ]; echo $?")
    end

    test "test command failure" do
      compare_bash("[ 1 -eq 2 ]; echo $?")
    end
  end

  describe "error suppression" do
    test "suppress stderr with 2>/dev/null" do
      compare_bash("cat /nonexistent_xyz_file 2>/dev/null; echo done")
    end

    test "grep no match exit code" do
      compare_bash("echo 'hello' | grep 'xyz'; echo $?")
    end

    test "test -f on nonexistent file" do
      compare_bash("test -f /nonexistent_xyz_file; echo $?")
    end

    test "test -d on nonexistent dir" do
      compare_bash("test -d /nonexistent_xyz_dir; echo $?")
    end
  end

  describe "AND/OR operators with exit codes" do
    test "AND with success" do
      compare_bash("true && echo success")
    end

    test "AND with failure" do
      compare_bash("false && echo success; echo $?")
    end

    test "OR with success" do
      compare_bash("true || echo fallback")
    end

    test "OR with failure" do
      compare_bash("false || echo fallback")
    end

    test "chained AND/OR" do
      compare_bash("false || true && echo end")
    end
  end
end
