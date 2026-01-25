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

  describe "echo -e escape sequences" do
    test "newline escape" do
      compare_bash(~S[echo -e "hello\nworld"])
    end

    test "tab escape" do
      compare_bash(~S[echo -e "col1\tcol2"])
    end

    test "carriage return escape" do
      compare_bash(~S[echo -e "hello\rworld"])
    end

    test "backslash escape" do
      compare_bash(~S[echo -e "back\\\\slash"])
    end

    test "hex escape lowercase" do
      compare_bash(~S[echo -e '\x41'])
    end

    test "hex escape uppercase" do
      compare_bash(~S[echo -e '\x41\x42\x43'])
    end

    test "hex escape mixed" do
      compare_bash(~S[echo -e 'hex:\x48\x45\x4c\x4c\x4f'])
    end

    test "octal escape" do
      compare_bash(~S[echo -e '\101'])
    end

    test "octal escape multiple" do
      compare_bash(~S[echo -e '\101\102\103'])
    end

    test "mixed text and hex" do
      compare_bash(~S[echo -e 'before\x41after'])
    end

    test "mixed text and octal" do
      compare_bash(~S[echo -e 'before\101after'])
    end
  end

  describe "$'...' ANSI-C quoting" do
    test "tab in dollar-single-quote" do
      compare_bash(~S[echo $'tab\ttab'])
    end

    test "newline in dollar-single-quote" do
      compare_bash(~S[echo $'line1\nline2'])
    end

    test "hex in dollar-single-quote" do
      compare_bash(~S[echo $'\x41\x42\x43'])
    end

    test "octal in dollar-single-quote" do
      compare_bash(~S[echo $'\101\102\103'])
    end

    test "backslash in dollar-single-quote" do
      compare_bash(~S[echo $'back\\slash'])
    end

    test "single quote in dollar-single-quote" do
      compare_bash(~S[echo $'it\'s quoted'])
    end

    test "double quote in dollar-single-quote" do
      compare_bash(~S[echo $'say "hello"'])
    end

    test "mixed escapes" do
      compare_bash(~S[echo $'A:\x41 tab:\t newline:\n'])
    end
  end

  describe "undefined variable behavior" do
    test "undefined variable expands to empty" do
      compare_bash(~S(echo "$undefined_var_xyz"))
    end

    test "undefined with braces" do
      compare_bash(~S(x=hello; echo "$x"))
    end

    test "undefined unquoted" do
      compare_bash(~S(echo $undefined_var_xyz end))
    end
  end
end
