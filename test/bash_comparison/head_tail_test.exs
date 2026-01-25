defmodule JustBash.BashComparison.HeadTailTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "head tail comparison" do
    test "head default" do
      compare_bash("echo -e '1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11' | head")
    end

    test "head specific count" do
      compare_bash("echo -e '1\n2\n3\n4\n5' | head -n 3")
    end

    test "tail default" do
      compare_bash("echo -e '1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11' | tail")
    end

    test "tail specific count" do
      compare_bash("echo -e '1\n2\n3\n4\n5' | tail -n 2")
    end

    test "tail from line" do
      compare_bash("echo -e '1\n2\n3\n4\n5' | tail -n +3")
    end
  end
end
