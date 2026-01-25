defmodule JustBash.BashComparison.ArithmeticTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "arithmetic expansion comparison" do
    test "simple addition" do
      compare_bash("echo $((1 + 2))")
    end

    test "nested parentheses" do
      compare_bash("echo $((1 + (2 * 3)))")
    end

    test "double nested" do
      compare_bash("echo $((1 + (2 + (3 + 4))))")
    end

    test "complex expression" do
      compare_bash("echo $(((2 + 3) * (4 + 5)))")
    end

    test "power" do
      compare_bash("echo $((2 ** 10))")
    end

    test "modulo" do
      compare_bash("echo $((17 % 5))")
    end

    test "comparison" do
      compare_bash("echo $((5 > 3))")
    end

    test "ternary" do
      compare_bash("echo $((5 > 3 ? 100 : 0))")
    end

    test "with variables" do
      compare_bash("x=5; y=3; echo $((x + y))")
    end
  end

  describe "arithmetic edge cases comparison" do
    test "negative numbers" do
      compare_bash("echo $((-5 + 3))")
    end

    test "negative modulo" do
      compare_bash("echo $((-7 % 3))")
    end

    test "bitwise and" do
      compare_bash("echo $((12 & 10))")
    end

    test "bitwise or" do
      compare_bash("echo $((12 | 10))")
    end

    test "bitwise xor" do
      compare_bash("echo $((12 ^ 10))")
    end

    test "left shift" do
      compare_bash("echo $((1 << 4))")
    end

    test "right shift" do
      compare_bash("echo $((16 >> 2))")
    end

    test "pre increment" do
      compare_bash("x=5; echo $((++x)) $x")
    end

    test "post increment" do
      compare_bash("x=5; echo $((x++)) $x")
    end
  end
end
