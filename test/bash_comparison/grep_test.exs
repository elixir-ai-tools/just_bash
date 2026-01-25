defmodule JustBash.BashComparison.GrepTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "grep comparison" do
    test "grep with line numbers" do
      compare_bash("echo -e 'a\\nb\\nc' | grep -n 'b'")
    end

    test "grep -E alternation" do
      compare_bash("echo -e 'foo\\nbar\\nbaz' | grep -E 'foo|bar'")
    end

    test "grep -v inverted match" do
      compare_bash("echo -e 'a\\nb\\nc' | grep -v 'b'")
    end

    test "grep -c count" do
      compare_bash("echo -e 'a\\nb\\na' | grep -c 'a'")
    end
  end
end
