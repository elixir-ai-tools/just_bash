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

  describe "sort edge cases" do
    test "empty input" do
      compare_bash("echo -n '' | sort")
    end

    test "single line" do
      compare_bash("echo 'hello' | sort")
    end

    test "already sorted" do
      compare_bash("echo -e 'a\nb\nc' | sort")
    end

    test "reverse already sorted" do
      compare_bash("echo -e 'c\nb\na' | sort -r")
    end

    test "numeric with negative numbers" do
      compare_bash("echo -e '5\n-3\n0\n-10\n7' | sort -n")
    end

    test "numeric with leading zeros" do
      compare_bash("echo -e '010\n2\n001' | sort -n")
    end

    test "case insensitive sort" do
      compare_bash("echo -e 'Banana\napple\nCherry' | sort -f")
    end

    test "sort combined flags -rn" do
      compare_bash("echo -e '10\n2\n1' | sort -rn")
    end

    test "sort combined flags -nu" do
      compare_bash("echo -e '3\n1\n2\n1\n3' | sort -nu")
    end

    test "sort with whitespace lines" do
      compare_bash("echo -e 'b\n   \na\n\nc' | sort")
    end

    test "sort duplicate lines" do
      compare_bash("echo -e 'a\na\na' | sort")
    end

    test "sort with mixed case" do
      compare_bash("echo -e 'a\nA\nb\nB' | sort")
    end

    test "numeric sort with non-numeric lines" do
      compare_bash("echo -e '10\nabc\n5' | sort -n")
    end

    test "sort by second field" do
      compare_bash("echo -e 'x 3\ny 1\nz 2' | sort -k2,2n")
    end

    test "sort by field range" do
      compare_bash("echo -e 'a b c\nd e f\ng h i' | sort -k1,2")
    end

    test "sort field with custom delimiter" do
      compare_bash("echo -e 'c:3\na:1\nb:2' | sort -t: -k2 -n")
    end

    test "sort unique with duplicates" do
      compare_bash("echo -e 'apple\norange\napple\nbanana\norange' | sort -u")
    end
  end
end
