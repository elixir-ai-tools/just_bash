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

  describe "tr comparison" do
    test "tr single char replacement" do
      compare_bash("echo 'hello' | tr 'l' 'L'")
    end

    test "tr space to newline" do
      compare_bash("echo 'a b c' | tr ' ' '\\n'")
    end

    test "tr delete characters" do
      compare_bash("echo 'hello' | tr -d 'l'")
    end

    test "tr character range lowercase to uppercase" do
      compare_bash("echo 'hello' | tr 'a-z' 'A-Z'")
    end
  end

  describe "grep comparison" do
    test "grep with line numbers" do
      compare_bash("echo -e 'a\\nb\\nc' | grep -n 'b'")
    end

    test "grep -E alternation" do
      compare_bash("echo -e 'foo\\nbar\\nbaz' | grep -E 'foo|bar'")
    end

    test "grep -v inverted match" do
      compare_bash("echo -e 'a\\nb\\nc' | grep -v 'b'")
    end

    test "grep -c count" do
      compare_bash("echo -e 'a\\nb\\na' | grep -c 'a'")
    end
  end

  describe "awk comparison" do
    test "awk print field" do
      compare_bash("echo 'a b c' | awk '{print $2}'")
    end

    test "awk with field separator" do
      compare_bash("echo 'a,b,c' | awk -F, '{print $2}'")
    end

    test "awk sum in END block" do
      compare_bash("echo -e '1\\n2\\n3' | awk '{s+=$1} END {print s}'")
    end

    test "awk NR line number" do
      compare_bash("echo -e 'a\\nb' | awk '{print NR, $0}'")
    end

    test "awk NF field count" do
      compare_bash("echo 'a b c d' | awk '{print NF}'")
    end
  end

  describe "sed comparison" do
    test "basic substitution" do
      compare_bash("echo 'hello' | sed 's/l/L/'")
    end

    test "global substitution" do
      compare_bash("echo 'hello' | sed 's/l/L/g'")
    end

    test "delete line" do
      compare_bash("echo -e 'a\nb\nc' | sed '2d'")
    end

    test "print specific line" do
      compare_bash("echo -e 'a\nb\nc' | sed -n '2p'")
    end

    test "address range" do
      compare_bash("echo -e 'a\nb\nc\nd' | sed -n '2,3p'")
    end

    test "regex address" do
      compare_bash("echo -e 'foo\nbar\nbaz' | sed -n '/ba/p'")
    end

    test "substitution with ampersand" do
      compare_bash("echo 'hello' | sed 's/l/[&]/g'")
    end

    test "case insensitive" do
      compare_bash("echo 'HELLO' | sed 's/hello/world/i'")
    end

    test "multiple expressions" do
      compare_bash("echo 'abc' | sed -e 's/a/A/' -e 's/c/C/'")
    end

    test "transliterate" do
      compare_bash("echo 'hello' | sed 'y/aeiou/AEIOU/'")
    end
  end

  describe "sort comparison" do
    test "basic sort" do
      compare_bash("echo -e 'c\na\nb' | sort")
    end

    test "reverse sort" do
      compare_bash("echo -e 'c\na\nb' | sort -r")
    end

    test "numeric sort" do
      compare_bash("echo -e '10\n2\n1' | sort -n")
    end

    test "unique sort" do
      compare_bash("echo -e 'a\nb\na\nc\nb' | sort -u")
    end

    test "sort by field" do
      compare_bash("echo -e 'b 2\na 1\nc 3' | sort -k2 -n")
    end
  end

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

  describe "uniq comparison" do
    test "basic uniq" do
      compare_bash("echo -e 'a\na\nb\nb\nc' | uniq")
    end

    # Skip: uniq -c padding differs between GNU (7 chars) and BSD (4 chars)
    @tag :skip
    test "uniq count" do
      compare_bash("echo -e 'a\na\nb' | uniq -c")
    end

    test "uniq duplicates only" do
      compare_bash("echo -e 'a\na\nb\nc\nc' | uniq -d")
    end

    test "uniq unique only" do
      compare_bash("echo -e 'a\na\nb\nc\nc' | uniq -u")
    end
  end

  describe "head tail comparison" do
    test "head default" do
      compare_bash("echo -e '1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11' | head")
    end

    test "head specific count" do
      compare_bash("echo -e '1\n2\n3\n4\n5' | head -n 3")
    end

    test "tail default" do
      compare_bash("echo -e '1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11' | tail")
    end

    test "tail specific count" do
      compare_bash("echo -e '1\n2\n3\n4\n5' | tail -n 2")
    end

    test "tail from line" do
      compare_bash("echo -e '1\n2\n3\n4\n5' | tail -n +3")
    end
  end

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

  describe "special variables comparison" do
    test "exit code variable" do
      compare_bash("true; echo $?")
    end

    test "exit code after false" do
      compare_bash("false; echo $?")
    end

    test "argument count" do
      compare_bash("set -- a b c; echo $#")
    end
  end

  describe "error output comparison" do
    test "command not found exit code" do
      compare_bash("nonexistent_cmd_xyz 2>/dev/null; echo $?", ignore_exit: true)
    end

    test "cat nonexistent file" do
      # Just check exit code, error message format may differ
      compare_bash("cat /nonexistent_file_xyz 2>/dev/null; echo $?", ignore_exit: true)
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

  describe "while read loops" do
    test "basic while read" do
      compare_bash(~S[echo -e "a\nb\nc" | while read x; do echo "got: $x"; done])
    end

    test "while read terminates on EOF" do
      compare_bash(~S[echo -e "1\n2\n3" | while read n; do echo $n; done; echo done])
    end

    test "while read with head" do
      compare_bash(~S[echo -e "1\n2\n3\n4\n5" | head -3 | while read x; do echo "x=$x"; done])
    end

    test "read returns 1 on empty input" do
      compare_bash(~S[echo "" | read x; echo $?])
    end
  end
end
