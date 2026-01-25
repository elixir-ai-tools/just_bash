defmodule JustBash.BashComparison.CutTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "cut comparison" do
    test "cut field with delimiter" do
      compare_bash("echo 'a,b,c' | cut -d, -f2")
    end

    test "cut multiple fields" do
      compare_bash("echo 'a,b,c,d' | cut -d, -f2,4")
    end

    test "cut field range" do
      compare_bash("echo 'a,b,c,d' | cut -d, -f2-3")
    end

    test "cut characters" do
      compare_bash("echo 'hello' | cut -c1-3")
    end

    test "cut from position to end" do
      compare_bash("echo 'hello' | cut -c3-")
    end
  end

  describe "cut edge cases" do
    test "single character" do
      compare_bash("echo 'hello' | cut -c1")
    end

    test "last character" do
      compare_bash("echo 'hello' | cut -c5")
    end

    test "character beyond length" do
      compare_bash("echo 'hi' | cut -c5")
    end

    test "first field" do
      compare_bash("echo 'a,b,c' | cut -d, -f1")
    end

    test "last field" do
      compare_bash("echo 'a,b,c' | cut -d, -f3")
    end

    test "field beyond count" do
      compare_bash("echo 'a,b' | cut -d, -f5")
    end

    test "field range from start" do
      compare_bash("echo 'a,b,c,d' | cut -d, -f-2")
    end

    test "field range to end" do
      compare_bash("echo 'a,b,c,d' | cut -d, -f2-")
    end

    test "field with tab delimiter default" do
      compare_bash("printf 'a\tb\tc' | cut -f2")
    end

    test "field with custom single-char delimiter" do
      compare_bash("echo 'a:b:c' | cut -d: -f2")
    end

    test "field with space delimiter" do
      compare_bash("echo 'a b c' | cut -d' ' -f2")
    end

    test "multiple character ranges" do
      compare_bash("echo 'hello world' | cut -c1-3,7-9")
    end

    test "overlapping character ranges" do
      compare_bash("echo 'hello' | cut -c1-3,2-4")
    end

    test "out of order fields (sorted output)" do
      compare_bash("echo 'a,b,c,d' | cut -d, -f3,1")
    end

    test "empty input" do
      compare_bash("echo -n '' | cut -c1")
    end

    test "multiline input" do
      compare_bash("echo -e 'a,b,c\nd,e,f' | cut -d, -f2")
    end

    test "line without delimiter (no -s flag)" do
      compare_bash("echo 'no-comma' | cut -d, -f1")
    end
  end
end
