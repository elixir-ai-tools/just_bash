defmodule JustBash.BashComparisonTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Tests that compare JustBash output against real bash.

  These tests run commands in both JustBash and real bash,
  then compare the outputs to ensure compatibility.

  Skipped by default. Run with: mix test --include bash_comparison
  """

  @moduletag :bash_comparison

  defp run_real_bash(cmd) do
    {output, exit_code} = System.cmd("bash", ["-c", cmd], stderr_to_stdout: true)
    {output, exit_code}
  end

  defp run_just_bash(cmd) do
    bash = JustBash.new()
    {result, _} = JustBash.exec(bash, cmd)
    # Combine stdout/stderr like bash does with stderr_to_stdout
    output = result.stdout <> result.stderr
    {output, result.exit_code}
  end

  defp compare_bash(cmd, opts \\ []) do
    {real_output, real_exit} = run_real_bash(cmd)
    {just_output, just_exit} = run_just_bash(cmd)

    ignore_exit = Keyword.get(opts, :ignore_exit, false)

    if ignore_exit do
      assert just_output == real_output,
             "Output mismatch for: #{cmd}\n" <>
               "Real bash: #{inspect(real_output)}\n" <>
               "JustBash:  #{inspect(just_output)}"
    else
      assert {just_output, just_exit} == {real_output, real_exit},
             "Mismatch for: #{cmd}\n" <>
               "Real bash: output=#{inspect(real_output)}, exit=#{real_exit}\n" <>
               "JustBash:  output=#{inspect(just_output)}, exit=#{just_exit}"
    end
  end

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

  describe "parameter expansion comparison" do
    test "simple variable" do
      compare_bash("x=hello; echo $x")
    end

    test "braced variable" do
      compare_bash("x=hello; echo ${x}")
    end

    test "default value unset" do
      compare_bash("echo ${x:-default}")
    end

    test "default value set" do
      compare_bash("x=value; echo ${x:-default}")
    end

    test "nested default" do
      compare_bash("echo ${x:-${y:-nested}}")
    end

    test "alternative when set" do
      compare_bash("x=hello; echo ${x:+world}")
    end

    test "alternative when unset" do
      compare_bash("echo ${x:+world}")
    end

    test "nested alternative" do
      compare_bash("x=hello; echo ${x:+${x}world}")
    end

    test "length" do
      compare_bash("x=hello; echo ${#x}")
    end

    # Note: ${x^^} and ${x,,} are bash 4+ features
    # macOS ships with bash 3.2, so we skip comparison
    @tag :skip
    test "uppercase" do
      compare_bash("x=hello; echo ${x^^}")
    end

    @tag :skip
    test "lowercase" do
      compare_bash("x=HELLO; echo ${x,,}")
    end

    test "suffix removal" do
      compare_bash("x=file.txt; echo ${x%.txt}")
    end

    test "prefix removal" do
      compare_bash("x=/path/to/file; echo ${x##*/}")
    end

    test "substring" do
      compare_bash("x=hello; echo ${x:1:3}")
    end
  end

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

  describe "command substitution comparison" do
    test "simple command" do
      compare_bash("echo $(echo hello)")
    end

    test "nested command substitution" do
      compare_bash("echo $(echo $(echo nested))")
    end

    test "with arithmetic" do
      compare_bash("echo $(echo $((1 + 2)))")
    end

    test "backtick style" do
      compare_bash("echo `echo hello`")
    end
  end

  describe "control flow comparison" do
    test "for loop with list" do
      compare_bash("for i in a b c; do echo $i; done")
    end

    test "for loop with range" do
      compare_bash("for i in {1..3}; do echo $i; done")
    end

    test "while loop" do
      compare_bash("x=3; while [ $x -gt 0 ]; do echo $x; x=$((x-1)); done")
    end

    test "if true" do
      compare_bash("if true; then echo yes; fi")
    end

    test "if false with else" do
      compare_bash("if false; then echo yes; else echo no; fi")
    end

    test "case statement" do
      compare_bash("x=b; case $x in a) echo A;; b) echo B;; esac")
    end
  end

  describe "pipeline comparison" do
    test "simple pipe" do
      compare_bash("echo hello | cat")
    end

    test "multiple pipes" do
      compare_bash("echo 'c\na\nb' | sort | head -1")
    end

    test "with grep" do
      compare_bash("echo -e 'foo\nbar\nbaz' | grep bar")
    end
  end

  describe "operators comparison" do
    test "and operator success" do
      compare_bash("true && echo yes")
    end

    test "and operator failure" do
      compare_bash("false && echo yes", ignore_exit: true)
    end

    test "or operator success" do
      compare_bash("true || echo no")
    end

    test "or operator failure" do
      compare_bash("false || echo yes")
    end

    test "mixed operators" do
      compare_bash("false && echo no || echo yes")
    end
  end
end
