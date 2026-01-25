defmodule JustBash.BashComparison.PrintfTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "printf comparison extended" do
    test "hex lowercase" do
      compare_bash("printf '%x\n' 255")
    end

    test "hex uppercase" do
      compare_bash("printf '%X\n' 255")
    end

    test "octal" do
      compare_bash("printf '%o\n' 64")
    end

    test "string with width" do
      compare_bash("printf '%10s\n' 'hi'")
    end

    test "left aligned" do
      compare_bash("printf '%-10s|\n' 'hi'")
    end

    test "multiple arguments" do
      compare_bash("printf '%s %s\n' hello world")
    end
  end
end
