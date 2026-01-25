defmodule JustBash.BashComparison.SortTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "sort comparison" do
    test "basic sort" do
      compare_bash("echo -e 'c\na\nb' | sort")
    end

    test "reverse sort" do
      compare_bash("echo -e 'c\na\nb' | sort -r")
    end

    test "numeric sort" do
      compare_bash("echo -e '10\n2\n1' | sort -n")
    end

    test "unique sort" do
      compare_bash("echo -e 'a\nb\na\nc\nb' | sort -u")
    end

    test "sort by field" do
      compare_bash("echo -e 'b 2\na 1\nc 3' | sort -k2 -n")
    end
  end
end
