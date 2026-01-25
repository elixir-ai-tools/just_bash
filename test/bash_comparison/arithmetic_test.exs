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

  describe "hex and octal literals" do
    test "hex literal lowercase" do
      compare_bash("echo $((0x1f))")
    end

    test "hex literal uppercase" do
      compare_bash("echo $((0X1F))")
    end

    test "hex in expression" do
      compare_bash("echo $((0x10 + 0x0f))")
    end

    test "octal literal" do
      compare_bash("echo $((017))")
    end

    test "octal in expression" do
      compare_bash("echo $((010 + 010))")
    end

    test "mixed bases" do
      compare_bash("echo $((0x10 + 010 + 10))")
    end
  end

  describe "bitwise NOT" do
    test "bitwise not of zero" do
      compare_bash("echo $((~0))")
    end

    test "bitwise not of positive" do
      compare_bash("echo $((~5))")
    end

    test "bitwise not of negative one" do
      compare_bash("echo $((~-1))")
    end

    test "double bitwise not" do
      compare_bash("echo $((~~5))")
    end

    test "bitwise not in expression" do
      compare_bash("echo $((~5 & 0xff))")
    end
  end

  describe "division by zero" do
    test "integer division by zero produces non-zero exit" do
      # Both should produce a non-zero exit code
      {_real_out, real_exit} = run_real_bash("echo $((1/0))")
      {just_out, just_exit} = run_just_bash("echo $((1/0))")

      # Real bash exits with 1
      assert real_exit == 1
      # JustBash should also exit with non-zero
      assert just_exit == 1
      # JustBash stderr should contain "division by 0"
      assert just_out =~ "division by 0"
    end

    test "modulo by zero produces non-zero exit" do
      {_real_out, real_exit} = run_real_bash("echo $((1%0))")
      {just_out, just_exit} = run_just_bash("echo $((1%0))")

      assert real_exit == 1
      assert just_exit == 1
      assert just_out =~ "division by 0"
    end
  end

  describe "increment and decrement" do
    test "pre-decrement" do
      compare_bash("x=5; echo $((--x)) $x")
    end

    test "post-decrement" do
      compare_bash("x=5; echo $((x--)) $x")
    end

    test "multiple increments" do
      compare_bash("x=0; echo $((x++)) $((x++)) $((x++))")
    end

    test "increment in expression" do
      compare_bash("x=5; echo $((x++ + ++x))")
    end
  end

  describe "compound assignment" do
    test "add-assign" do
      compare_bash("x=10; echo $((x += 5)) $x")
    end

    test "subtract-assign" do
      compare_bash("x=10; echo $((x -= 3)) $x")
    end

    test "multiply-assign" do
      compare_bash("x=10; echo $((x *= 2)) $x")
    end

    test "divide-assign" do
      compare_bash("x=10; echo $((x /= 2)) $x")
    end

    test "modulo-assign" do
      compare_bash("x=10; echo $((x %= 3)) $x")
    end
  end

  describe "logical operators" do
    test "logical and true" do
      compare_bash("echo $((5 && 3))")
    end

    test "logical and false" do
      compare_bash("echo $((5 && 0))")
    end

    test "logical or true" do
      compare_bash("echo $((0 || 3))")
    end

    test "logical or false" do
      compare_bash("echo $((0 || 0))")
    end

    test "logical not" do
      compare_bash("echo $((!0)) $((!5))")
    end
  end
end
