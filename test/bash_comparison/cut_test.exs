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
end
