defmodule JustBash.BashComparison.ParameterExpansionTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "parameter expansion comparison" do
    test "simple variable" do
      compare_bash("x=hello; echo $x")
    end

    test "braced variable" do
      compare_bash("x=hello; echo ${x}")
    end

    test "default value unset" do
      compare_bash("echo ${x:-default}")
    end

    test "default value set" do
      compare_bash("x=value; echo ${x:-default}")
    end

    test "nested default" do
      compare_bash("echo ${x:-${y:-nested}}")
    end

    test "alternative when set" do
      compare_bash("x=hello; echo ${x:+world}")
    end

    test "alternative when unset" do
      compare_bash("echo ${x:+world}")
    end

    test "nested alternative" do
      compare_bash("x=hello; echo ${x:+${x}world}")
    end

    test "length" do
      compare_bash("x=hello; echo ${#x}")
    end

    # Note: ${x^^} and ${x,,} are bash 4+ features
    # macOS ships with bash 3.2, so we skip comparison
    @tag :skip
    test "uppercase" do
      compare_bash("x=hello; echo ${x^^}")
    end

    @tag :skip
    test "lowercase" do
      compare_bash("x=HELLO; echo ${x,,}")
    end

    test "suffix removal" do
      compare_bash("x=file.txt; echo ${x%.txt}")
    end

    test "prefix removal" do
      compare_bash("x=/path/to/file; echo ${x##*/}")
    end

    test "substring" do
      compare_bash("x=hello; echo ${x:1:3}")
    end
  end
end
