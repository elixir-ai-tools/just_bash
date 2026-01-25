defmodule JustBash.BashComparison.ControlFlowTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "control flow comparison" do
    test "for loop with list" do
      compare_bash("for i in a b c; do echo $i; done")
    end

    test "for loop with range" do
      compare_bash("for i in {1..3}; do echo $i; done")
    end

    test "while loop" do
      compare_bash("x=3; while [ $x -gt 0 ]; do echo $x; x=$((x-1)); done")
    end

    test "if true" do
      compare_bash("if true; then echo yes; fi")
    end

    test "if false with else" do
      compare_bash("if false; then echo yes; else echo no; fi")
    end

    test "case statement" do
      compare_bash("x=b; case $x in a) echo A;; b) echo B;; esac")
    end
  end
end
