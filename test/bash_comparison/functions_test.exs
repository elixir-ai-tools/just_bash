defmodule JustBash.BashComparison.FunctionsTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "function definition and calling" do
    test "basic function with parens syntax" do
      compare_bash(~s|greet() { echo "hello"; }; greet|)
    end

    test "function keyword syntax" do
      compare_bash(~s|function greet { echo "hi"; }; greet|)
    end

    test "function with arguments" do
      compare_bash(~s|add() { echo $(($1 + $2)); }; add 3 5|)
    end

    test "function with local variable" do
      compare_bash(~s|counter() { local x=10; echo $x; }; counter|)
    end

    test "local variable isolation" do
      compare_bash(~s|x=outer; inner() { local x=inner; echo $x; }; inner; echo $x|)
    end

    test "function output capture" do
      compare_bash(~s|get_val() { echo "result"; }; out=$(get_val); echo $out|)
    end

    test "function can be overwritten" do
      compare_bash(~s|f() { echo "first"; }; f() { echo "second"; }; f|)
    end

    test "function with default parameter pattern" do
      compare_bash(~s|with_default() { echo "${1:-default}"; }; with_default|)
    end

    test "function with default parameter override" do
      compare_bash(~s|with_default() { echo "${1:-default}"; }; with_default custom|)
    end

    test "function with multiple outputs" do
      compare_bash(~s|multi() { echo "line1"; echo "line2"; }; multi|)
    end
  end

  describe "function arguments and positional parameters" do
    test "access multiple arguments" do
      compare_bash(~s|f() { echo "$1 $2 $3"; }; f a b c|)
    end

    test "argument count in function" do
      compare_bash(~s|f() { echo $#; }; f a b c d|)
    end

    test "all arguments with @" do
      compare_bash(~s|f() { echo "$@"; }; f one two three|)
    end

    test "all arguments with *" do
      compare_bash(~s|f() { echo "$*"; }; f one two three|)
    end

    test "undefined argument is empty" do
      compare_bash(~s|f() { echo "[$1][$2][$3]"; }; f only_one|)
    end
  end

  describe "function with complex bodies" do
    test "function with loop" do
      compare_bash(~s|loop_func() { for i in 1 2 3; do echo $i; done; }; loop_func|)
    end

    test "function with conditional" do
      compare_bash(~s|check() { if [ "$1" = "yes" ]; then echo "ok"; else echo "no"; fi; }; check yes|)
    end

    test "function calling another function" do
      compare_bash(~s|inner() { echo "inner"; }; outer() { inner; echo "outer"; }; outer|)
    end

    test "recursive function" do
      compare_bash(~s|countdown() { if [ $1 -gt 0 ]; then echo $1; countdown $(($1 - 1)); fi; }; countdown 3|)
    end
  end

  describe "function exit codes" do
    test "function returns 0 by default" do
      compare_bash(~s|f() { echo hi; }; f; echo $?|)
    end

    test "function returns exit code of last command" do
      compare_bash(~s|f() { false; }; f; echo $?|)
    end

    test "function returns success from last command" do
      compare_bash(~s|f() { false; true; }; f; echo $?|)
    end
  end
end
