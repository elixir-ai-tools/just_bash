defmodule JustBash.BashComparison.SpecialVariablesTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "special variables comparison" do
    test "exit code variable" do
      compare_bash("true; echo $?")
    end

    test "exit code after false" do
      compare_bash("false; echo $?")
    end

    test "argument count" do
      compare_bash("set -- a b c; echo $#")
    end
  end
end
