defmodule JustBash.BashComparison.QuotingTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "quoting comparison" do
    test "double quotes preserve spaces" do
      compare_bash("echo \"hello   world\"")
    end

    test "single quotes are literal" do
      compare_bash("echo '$HOME'")
    end

    test "double quotes expand variables" do
      compare_bash("x=test; echo \"value: $x\"")
    end

    test "escaped dollar in double quotes" do
      compare_bash("echo \"\\$HOME\"")
    end

    test "mixed quoting" do
      compare_bash("echo 'single'\"double\"unquoted")
    end
  end

  describe "quoting edge cases comparison" do
    test "escaped double quote" do
      compare_bash(~s[echo "it's \\"quoted\\""])
    end

    test "single quote escape" do
      compare_bash("echo 'it'\\''s quoted'")
    end

    test "dollar literal in single quotes" do
      compare_bash("echo '$HOME'")
    end

    test "empty string argument" do
      compare_bash("echo '' 'a'")
    end

    test "word splitting" do
      compare_bash("x='a   b'; echo $x")
    end

    test "no word splitting in quotes" do
      compare_bash("x='a   b'; echo \"$x\"")
    end
  end

  describe "single quotes inside double quotes" do
    test "apostrophe in string" do
      compare_bash(~S[X="it's"; echo "$X"])
    end

    test "SQL-style single quotes" do
      compare_bash(~S[X="VALUES ('hello')"; echo "$X"])
    end

    test "multiple single quotes" do
      compare_bash(~S[X="'a' 'b' 'c'"; echo "$X"])
    end

    test "building SQL string incrementally" do
      compare_bash(
        ~S[SQL="INSERT INTO t VALUES ('x');"; SQL="$SQL INSERT INTO t VALUES ('y');"; echo "$SQL"]
      )
    end

    test "single quote at boundaries" do
      compare_bash(~S[X="'start"; echo "$X"])
      compare_bash(~S[X="end'"; echo "$X"])
    end
  end
end
