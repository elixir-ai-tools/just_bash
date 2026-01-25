defmodule JustBash.BashComparison.OperatorsTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "operators comparison" do
    test "and operator success" do
      compare_bash("true && echo yes")
    end

    test "and operator failure" do
      compare_bash("false && echo yes", ignore_exit: true)
    end

    test "or operator success" do
      compare_bash("true || echo no")
    end

    test "or operator failure" do
      compare_bash("false || echo yes")
    end

    test "mixed operators" do
      compare_bash("false && echo no || echo yes")
    end
  end
end
