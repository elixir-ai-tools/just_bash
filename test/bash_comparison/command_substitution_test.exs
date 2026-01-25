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
end
