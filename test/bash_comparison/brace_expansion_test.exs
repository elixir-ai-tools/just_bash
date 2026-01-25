defmodule JustBash.BashComparison.BraceExpansionTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "brace expansion comparison" do
    test "simple list" do
      compare_bash("echo {a,b,c}")
    end

    test "numeric range" do
      compare_bash("echo {1..5}")
    end

    test "descending range" do
      compare_bash("echo {5..1}")
    end

    test "character range" do
      compare_bash("echo {a..e}")
    end

    test "with prefix" do
      compare_bash("echo pre{a,b,c}")
    end

    test "with suffix" do
      compare_bash("echo {a,b,c}post")
    end

    test "with prefix and suffix" do
      compare_bash("echo pre{a,b,c}post")
    end

    test "nested braces" do
      compare_bash("echo {a,{b,c}}")
    end

    test "multiple expansions" do
      compare_bash("echo {a,b}{1,2}")
    end

    test "single element not expanded" do
      compare_bash("echo {a}")
    end

    test "empty braces literal" do
      compare_bash("echo {}")
    end

    test "negative range" do
      compare_bash("echo {-2..2}")
    end
  end
end
