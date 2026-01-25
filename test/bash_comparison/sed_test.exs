defmodule JustBash.BashComparison.SedTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "sed comparison" do
    test "basic substitution" do
      compare_bash("echo 'hello' | sed 's/l/L/'")
    end

    test "global substitution" do
      compare_bash("echo 'hello' | sed 's/l/L/g'")
    end

    test "delete line" do
      compare_bash("echo -e 'a\nb\nc' | sed '2d'")
    end

    test "print specific line" do
      compare_bash("echo -e 'a\nb\nc' | sed -n '2p'")
    end

    test "address range" do
      compare_bash("echo -e 'a\nb\nc\nd' | sed -n '2,3p'")
    end

    test "regex address" do
      compare_bash("echo -e 'foo\nbar\nbaz' | sed -n '/ba/p'")
    end

    test "substitution with ampersand" do
      compare_bash("echo 'hello' | sed 's/l/[&]/g'")
    end

    test "case insensitive" do
      compare_bash("echo 'HELLO' | sed 's/hello/world/i'")
    end

    test "multiple expressions" do
      compare_bash("echo 'abc' | sed -e 's/a/A/' -e 's/c/C/'")
    end

    test "transliterate" do
      compare_bash("echo 'hello' | sed 'y/aeiou/AEIOU/'")
    end
  end
end
