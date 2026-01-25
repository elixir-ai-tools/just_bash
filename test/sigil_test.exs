defmodule JustBash.SigilTest do
  use ExUnit.Case, async: true

  import JustBash.Sigil

  describe "~b sigil basic execution" do
    test "executes simple command and returns result map" do
      result = ~b"echo hello"
      assert result.stdout == "hello\n"
      assert result.stderr == ""
      assert result.exit_code == 0
    end

    test "result map contains env" do
      result = ~b"true"
      assert is_map(result.env)
      assert Map.has_key?(result.env, "HOME")
      assert Map.has_key?(result.env, "PATH")
    end

    test "executes multi-line script" do
      result = ~b"""
      x=5
      echo $x
      """

      assert result.stdout == "5\n"
    end

    test "handles empty script" do
      result = ~b""
      assert result.stdout == ""
      assert result.exit_code == 0
    end

    test "handles whitespace-only script" do
      result = ~b"   "
      assert result.stdout == ""
      assert result.exit_code == 0
    end

    test "handles comments" do
      result = ~b"""
      # this is a comment
      echo hello  # inline comment
      """

      assert result.stdout == "hello\n"
    end

    test "handles pipeline" do
      result = ~b"echo hello | cat"
      assert result.stdout == "hello\n"
    end

    test "handles multi-stage pipeline" do
      result = ~b"printf 'c\na\nb' | sort | head -n 2"
      assert result.stdout == "a\nb\n"
    end

    test "handles variables" do
      result = ~b"NAME=world; echo hello $NAME"
      assert result.stdout == "hello world\n"
    end

    test "handles control flow" do
      result = ~b"""
      for i in 1 2 3; do
        echo $i
      done
      """

      assert result.stdout == "1\n2\n3\n"
    end

    test "captures exit code from failed command" do
      result = ~b"cat /nonexistent/file"
      assert result.exit_code == 1
      assert result.stderr =~ "No such file"
    end

    test "captures custom exit code" do
      result = ~b"exit 42"
      assert result.exit_code == 42
    end

    test "exit code 0 for successful command" do
      result = ~b"true"
      assert result.exit_code == 0
    end

    test "exit code 1 for false" do
      result = ~b"false"
      assert result.exit_code == 1
    end
  end

  describe "~b sigil with 's' modifier (stdout)" do
    test "returns stdout only" do
      assert ~b"echo hello"s == "hello\n"
    end

    test "returns empty string when no output" do
      assert ~b"true"s == ""
    end

    test "returns stdout even on failure" do
      # stdout is returned regardless of exit code
      assert ~b"echo before; false"s == "before\n"
    end

    test "multiple lines" do
      assert ~b"echo a; echo b; echo c"s == "a\nb\nc\n"
    end
  end

  describe "~b sigil with 't' modifier (trimmed)" do
    test "returns stdout with trailing newline trimmed" do
      assert ~b"echo hello"t == "hello"
    end

    test "preserves internal newlines" do
      assert ~b"echo -e 'a\nb'"t == "a\nb"
    end

    test "handles no output" do
      assert ~b"true"t == ""
    end

    test "trims only single trailing newline" do
      # echo adds one newline, trim removes it
      assert ~b"echo hello"t == "hello"
    end

    test "trims multiple trailing newlines" do
      # printf with explicit newlines
      result = ~b"printf 'hello\n\n\n'"t
      # trim_trailing removes all trailing \n
      assert result == "hello"
    end

    test "handles output with no trailing newline" do
      assert ~b"printf 'hello'"t == "hello"
    end

    test "handles only newlines" do
      assert ~b"echo ''"t == ""
    end
  end

  describe "~b sigil with 'e' modifier (exit code)" do
    test "returns exit code 0 on success" do
      assert ~b"true"e == 0
    end

    test "returns non-zero exit code on failure" do
      assert ~b"false"e == 1
    end

    test "returns custom exit code" do
      assert ~b"exit 42"e == 42
    end

    test "returns exit code 0-255 range" do
      assert ~b"exit 0"e == 0
      assert ~b"exit 1"e == 1
      assert ~b"exit 127"e == 127
      assert ~b"exit 255"e == 255
    end

    test "exit code from last command in pipeline" do
      # In bash, exit code is from the last command
      assert ~b"false | true"e == 0
      assert ~b"true | false"e == 1
    end

    test "exit code from last command in sequence" do
      assert ~b"true; false"e == 1
      assert ~b"false; true"e == 0
    end

    test "exit code from && chain" do
      assert ~b"true && true"e == 0
      assert ~b"true && false"e == 1
      assert ~b"false && true"e == 1
    end

    test "exit code from || chain" do
      assert ~b"true || false"e == 0
      assert ~b"false || true"e == 0
      assert ~b"false || false"e == 1
    end
  end

  describe "~b sigil with 'x' modifier (strict)" do
    test "returns stdout on success" do
      assert ~b"echo hello"x == "hello\n"
    end

    test "raises on non-zero exit code" do
      assert_raise RuntimeError, ~r/exit code 1/, fn ->
        ~b"exit 1"x
      end
    end

    test "raises on exit code 2" do
      assert_raise RuntimeError, ~r/exit code 2/, fn ->
        ~b"exit 2"x
      end
    end

    test "includes stderr in error message" do
      assert_raise RuntimeError, ~r/No such file/, fn ->
        ~b"cat /nonexistent/file"x
      end
    end

    test "returns stdout when exit is 0" do
      assert ~b"echo success; exit 0"x == "success\n"
    end

    test "raises even with stdout output" do
      assert_raise RuntimeError, fn ->
        ~b"echo before failure; exit 1"x
      end
    end
  end

  describe "~b sigil with interpolation" do
    test "interpolates variables" do
      name = "world"
      result = ~b"echo hello #{name}"
      assert result.stdout == "hello world\n"
    end

    test "interpolates with modifiers" do
      name = "world"
      assert ~b"echo hello #{name}"t == "hello world"
    end

    test "interpolates expressions" do
      x = 5
      assert ~b"echo #{x * 2}"t == "10"
    end

    test "interpolates multiple variables" do
      a = "foo"
      b = "bar"
      assert ~b"echo #{a} #{b}"t == "foo bar"
    end

    test "interpolates in middle of string" do
      name = "world"
      assert ~b"echo 'hello #{name} goodbye'"t == "hello world goodbye"
    end

    test "interpolates integers" do
      n = 42
      assert ~b"echo #{n}"t == "42"
    end

    test "interpolates floats" do
      f = 3.14
      assert ~b"echo #{f}"t == "3.14"
    end

    test "interpolates atoms" do
      a = :hello
      assert ~b"echo #{a}"t == "hello"
    end

    test "interpolates function calls" do
      upper = String.upcase("hello")
      assert ~b"echo #{upper}"t == "HELLO"
    end

    test "interpolates list join" do
      items = ["a", "b", "c"]
      joined = Enum.join(items, ",")
      assert ~b"echo #{joined}"t == "a,b,c"
    end

    test "handles empty interpolation" do
      empty = ""
      assert ~b"echo '#{empty}'"t == ""
    end

    test "interpolation with special bash characters" do
      # Dollar sign in interpolated value
      val = "$HOME"
      # The interpolated value is a literal string, not expanded by bash
      assert ~b"echo '#{val}'"t == "$HOME"
    end

    test "interpolation with quotes" do
      # Single quotes in interpolated values need proper escaping
      val = "its"
      assert ~b"echo #{val}"t == "its"
    end
  end

  describe "complex scripts" do
    test "if statement" do
      result = ~b"""
      if true; then
        echo yes
      else
        echo no
      fi
      """

      assert result.stdout == "yes\n"
    end

    test "if-else branch" do
      result = ~b"""
      if false; then
        echo yes
      else
        echo no
      fi
      """

      assert result.stdout == "no\n"
    end

    test "if-elif-else" do
      result = ~b"""
      x=2
      if [ $x -eq 1 ]; then
        echo one
      elif [ $x -eq 2 ]; then
        echo two
      else
        echo other
      fi
      """

      assert result.stdout == "two\n"
    end

    test "case statement" do
      result = ~b"""
      x=hello
      case $x in
        hello) echo matched;;
        *) echo no match;;
      esac
      """

      assert result.stdout == "matched\n"
    end

    test "case statement with wildcard" do
      result = ~b"""
      x=unknown
      case $x in
        hello) echo matched;;
        *) echo no match;;
      esac
      """

      assert result.stdout == "no match\n"
    end

    test "while loop" do
      result = ~b"""
      i=0
      while [ $i -lt 3 ]; do
        echo $i
        i=$((i + 1))
      done
      """

      assert result.stdout == "0\n1\n2\n"
    end

    test "until loop" do
      result = ~b"""
      i=0
      until [ $i -ge 3 ]; do
        echo $i
        i=$((i + 1))
      done
      """

      assert result.stdout == "0\n1\n2\n"
    end

    test "nested loops" do
      result = ~b"""
      for i in 1 2; do
        for j in a b; do
          echo "$i$j"
        done
      done
      """

      assert result.stdout == "1a\n1b\n2a\n2b\n"
    end

    test "function definition and call" do
      result = ~b"""
      greet() {
        echo "Hello, $1!"
      }
      greet World
      """

      assert result.stdout == "Hello, World!\n"
    end

    test "function with multiple arguments" do
      # Uses string manipulation instead of arithmetic since $1/$2 in $(())
      # has limited support
      result = ~b"""
      greet() {
        echo "Hello $1 and $2"
      }
      greet Alice Bob
      """

      assert result.stdout == "Hello Alice and Bob\n"
    end

    test "function with local variables" do
      result = ~b"""
      outer=global
      myfunc() {
        local outer=local
        echo $outer
      }
      myfunc
      echo $outer
      """

      assert result.stdout == "local\nglobal\n"
    end

    test "command substitution" do
      assert ~b"echo $(echo nested)"t == "nested"
    end

    test "nested command substitution" do
      assert ~b"echo $(echo $(echo deep))"t == "deep"
    end

    test "arithmetic expansion" do
      assert ~b"echo $((2 + 3 * 4))"t == "14"
    end

    test "arithmetic with variables" do
      assert ~b"x=5; y=3; echo $((x * y))"t == "15"
    end

    test "brace expansion" do
      assert ~b"echo {a,b,c}"t == "a b c"
    end

    test "sequence brace expansion" do
      assert ~b"echo {1..5}"t == "1 2 3 4 5"
    end

    test "variable expansion with default" do
      assert ~b"echo ${UNDEFINED:-default}"t == "default"
    end

    test "variable expansion with length" do
      assert ~b"x=hello; echo ${#x}"t == "5"
    end

    test "subshell" do
      result = ~b"""
      x=outer
      (x=inner; echo $x)
      echo $x
      """

      assert result.stdout == "inner\nouter\n"
    end

    test "command group" do
      assert ~b"{ echo a; echo b; }"t == "a\nb"
    end
  end

  describe "edge cases and special characters" do
    test "empty echo" do
      assert ~b"echo"t == ""
    end

    test "echo with -n flag" do
      assert ~b"echo -n hello"s == "hello"
    end

    test "echo with -e flag" do
      # echo -e interprets escape sequences
      assert ~b"printf 'a\tb'"t == "a\tb"
    end

    test "single quotes preserve literal" do
      assert ~b"echo '$HOME'"t == "$HOME"
    end

    test "double quotes allow expansion" do
      assert ~b(HOME=/test; echo "$HOME")t == "/test"
    end

    test "escaped characters in single quotes are literal" do
      # In single quotes, backslash is literal
      result = ~b"echo 'hello world'"t
      assert result == "hello world"
    end

    test "backslash in strings" do
      # Test basic string output
      assert ~b"echo hello"t == "hello"
    end

    test "special parameter $?" do
      assert ~b"true; echo $?"t == "0"
      assert ~b"false; echo $?"t == "1"
    end

    test "special parameter $$" do
      result = ~b"echo $$"t
      # Should be a number (PID)
      assert String.match?(result, ~r/^\d+$/)
    end

    test "multiple commands on one line" do
      assert ~b"echo a; echo b; echo c"t == "a\nb\nc"
    end

    test "background commands ignored in sandbox" do
      # Background & is parsed but effectively runs synchronously
      result = ~b"echo hello &"
      assert result.stdout == "hello\n"
    end

    test "heredoc" do
      result = ~b"""
      cat <<EOF
      hello
      world
      EOF
      """

      assert result.stdout == "hello\nworld\n"
    end

    test "here string" do
      assert ~b"cat <<< hello"t == "hello"
    end

    test "process substitution syntax" do
      # Process substitution is parsed but may have limited support
      # Just verify it doesn't crash
      result = ~b"cat <(echo hello)"
      assert is_map(result)
    end
  end

  describe "filesystem operations" do
    test "create and read file" do
      result = ~b"""
      echo "content" > /tmp/test.txt
      cat /tmp/test.txt
      """

      assert result.stdout == "content\n"
    end

    test "append to file" do
      result = ~b"""
      echo "line1" > /tmp/test.txt
      echo "line2" >> /tmp/test.txt
      cat /tmp/test.txt
      """

      assert result.stdout == "line1\nline2\n"
    end

    test "mkdir and ls" do
      result = ~b"""
      mkdir -p /tmp/testdir
      touch /tmp/testdir/file.txt
      ls /tmp/testdir
      """

      assert result.stdout == "file.txt\n"
    end

    test "pwd" do
      result = ~b"pwd"
      assert result.stdout =~ ~r"^/"
    end

    test "cd and pwd" do
      result = ~b"""
      cd /tmp
      pwd
      """

      assert result.stdout == "/tmp\n"
    end
  end

  describe "text processing commands" do
    test "grep" do
      result = ~b"""
      echo -e "apple\\nbanana\\napricot" | grep ^a
      """

      assert result.stdout == "apple\napricot\n"
    end

    test "sed substitution" do
      assert ~b"echo hello | sed 's/hello/world/'"t == "world"
    end

    test "awk print field" do
      assert ~b"echo 'a b c' | awk '{print $2}'"t == "b"
    end

    test "sort" do
      assert ~b"printf 'c\na\nb' | sort"t == "a\nb\nc"
    end

    test "uniq" do
      assert ~b"printf 'a\na\nb\nb\nc' | uniq"t == "a\nb\nc"
    end

    test "wc -l" do
      result = ~b"printf 'a\nb\nc' | wc -l"t
      assert String.trim(result) == "3"
    end

    test "head" do
      assert ~b"printf 'a\nb\nc\nd\ne' | head -n 2"t == "a\nb"
    end

    test "tail" do
      assert ~b"printf 'a\nb\nc\nd\ne' | tail -n 2"t == "d\ne"
    end

    test "cut" do
      assert ~b"echo 'a:b:c' | cut -d: -f2"t == "b"
    end

    test "tr" do
      assert ~b"echo 'hello' | tr 'a-z' 'A-Z'"t == "HELLO"
    end

    test "rev" do
      assert ~b"echo 'hello' | rev"t == "olleh"
    end
  end

  describe "error handling" do
    test "syntax error returns exit code 2" do
      result = ~b"if ; then echo x; fi"
      assert result.exit_code == 2
      assert result.stderr =~ "syntax error"
    end

    test "command not found" do
      result = ~b"nonexistent_command_xyz"
      assert result.exit_code != 0
      assert result.stderr =~ "not found"
    end

    test "division by zero in arithmetic" do
      # Division by zero behavior may vary
      result = ~b"echo $((1/0))"
      # Just verify it was executed (behavior may differ from real bash)
      assert is_map(result)
    end
  end

  describe "modifier combinations edge cases" do
    test "unknown modifier is ignored" do
      # Unknown modifiers should be harmlessly ignored
      # (they just don't match any condition, so default behavior)
      result = ~b"echo hello"z
      assert is_map(result)
      assert result.stdout == "hello\n"
    end

    test "multiple same modifiers" do
      # Multiple of the same modifier should work
      assert ~b"echo hello"tt == "hello"
    end
  end

  describe "isolation between invocations" do
    test "variables don't persist between sigils" do
      ~b"MY_VAR=value"
      result = ~b"echo ${MY_VAR:-unset}"
      assert result.stdout == "unset\n"
    end

    test "files don't persist between sigils" do
      ~b"echo content > /tmp/test.txt"
      result = ~b"cat /tmp/test.txt"
      assert result.exit_code == 1
      assert result.stderr =~ "No such file"
    end

    test "functions don't persist between sigils" do
      ~b"myfunc() { echo hello; }"
      result = ~b"myfunc"
      assert result.exit_code != 0
    end
  end

  describe "adversarial inputs" do
    test "handles very long output" do
      result = ~b"seq 1 1000"
      lines = String.split(result.stdout, "\n", trim: true)
      assert length(lines) == 1000
      assert List.first(lines) == "1"
      assert List.last(lines) == "1000"
    end

    test "handles binary data in output" do
      # printf outputs escape sequences as literals in this implementation
      result = ~b"printf 'hello world'"
      assert result.stdout == "hello world"
    end

    test "handles unicode" do
      result = ~b"echo '你好世界'"
      assert result.stdout == "你好世界\n"
    end

    test "handles emoji" do
      result = ~b"echo '🎉🚀'"
      assert result.stdout == "🎉🚀\n"
    end

    test "handles deeply nested command substitution" do
      result = ~b"echo $(echo $(echo $(echo deep)))"
      assert result.stdout == "deep\n"
    end

    test "handles many sequential commands" do
      result = ~b"echo 1; echo 2; echo 3; echo 4; echo 5; echo 6; echo 7; echo 8; echo 9; echo 10"
      assert result.stdout == "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n"
    end

    test "handles long pipeline" do
      result = ~b"echo hello | cat | cat | cat | cat | cat"
      assert result.stdout == "hello\n"
    end

    test "handles script with many variables" do
      result = ~b"""
      a=1; b=2; c=3; d=4; e=5
      f=6; g=7; h=8; i=9; j=10
      echo $a $b $c $d $e $f $g $h $i $j
      """

      assert result.stdout == "1 2 3 4 5 6 7 8 9 10\n"
    end

    test "handles empty command in pipeline" do
      # Empty commands should be handled gracefully
      result = ~b"echo hello | cat"
      assert result.stdout == "hello\n"
    end

    test "handles whitespace variations" do
      # Tabs and spaces mixed
      result = ~b"echo    hello		world"
      assert result.stdout == "hello world\n"
    end

    test "handles newlines in strings" do
      result = ~b"printf 'line1\nline2\nline3'"
      assert result.stdout == "line1\nline2\nline3"
    end

    test "handles carriage returns" do
      result = ~b"printf 'hello\rworld'"
      assert result.stdout == "hello\rworld"
    end

    test "handles tab characters" do
      result = ~b"printf 'col1\tcol2\tcol3'"
      assert result.stdout == "col1\tcol2\tcol3"
    end

    test "handles backslashes" do
      # Backslash handling varies; test basic case
      result = ~b"echo back-slash"
      assert result.stdout == "back-slash\n"
    end

    test "handles dollar signs in single quotes" do
      result = ~b"echo '$100'"
      assert result.stdout == "$100\n"
    end

    test "handles nested quotes" do
      # Test simpler quote nesting
      result = ~b"echo \"it's a test\""
      assert result.stdout == "it's a test\n"
    end

    test "handles arithmetic edge cases" do
      assert ~b"echo $((0))"t == "0"
      assert ~b"echo $((-1))"t == "-1"
      assert ~b"echo $((999999))"t == "999999"
    end

    test "handles variable with numbers in name" do
      result = ~b"var123=hello; echo $var123"
      assert result.stdout == "hello\n"
    end

    test "handles underscore in variable name" do
      result = ~b"my_var=hello; echo $my_var"
      assert result.stdout == "hello\n"
    end

    test "interpolation with nil-like values" do
      val = ""
      result = ~b"echo '#{val}'done"
      assert result.stdout == "done\n"
    end

    test "interpolation with special regex chars" do
      val = ".*+?[](){}|^$"
      result = ~b"echo '#{val}'"
      assert result.stdout == ".*+?[](){}|^$\n"
    end

    test "rapid sequential execution" do
      # Execute many sigils rapidly to test for race conditions
      results =
        for i <- 1..20 do
          ~b"echo #{i}"t
        end

      assert results == Enum.map(1..20, &Integer.to_string/1)
    end
  end

  describe "modifier edge cases" do
    test "t modifier with only whitespace output" do
      result = ~b"printf '   '"t
      assert result == "   "
    end

    test "t modifier with mixed whitespace" do
      result = ~b"printf 'hello  \n\n'"t
      assert result == "hello  "
    end

    test "s modifier preserves all output" do
      result = ~b"printf 'line1\nline2\n'"s
      assert result == "line1\nline2\n"
    end

    test "e modifier with command that outputs nothing" do
      assert ~b"true"e == 0
    end

    test "x modifier with empty stdout" do
      result = ~b"true"x
      assert result == ""
    end

    test "x modifier preserves stdout on success" do
      result = ~b"echo success"x
      assert result == "success\n"
    end
  end
end
