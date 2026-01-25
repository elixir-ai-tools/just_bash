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
end
