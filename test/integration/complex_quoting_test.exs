defmodule JustBash.Integration.ComplexQuotingTest do
  @moduledoc """
  Comprehensive tests for complex quoting scenarios.

  These tests cover edge cases with nested quotes, command substitution,
  and special characters that have historically caused parser issues.
  """

  use ExUnit.Case, async: true

  describe "command substitution with various quote combinations" do
    test "single quotes containing double quotes inside $()" do
      script = "x=$(echo '\"hello\"'); echo \"$x\""
      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "\"hello\"\n"
    end

    test "double quotes containing single quotes inside $()" do
      script = "x=$(echo \"'hello'\"); echo \"$x\""
      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "'hello'\n"
    end

    test "escaped quotes inside double-quoted $()" do
      # In bash: x="$(echo \"test\")"; echo "$x" outputs "test" with quotes
      # The \" inside $() passes literal quotes to echo
      script = "x=\"$(echo \\\"test\\\")\"; echo \"$x\""
      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "\"test\"\n"
    end

    test "parentheses inside single quotes inside $()" do
      script = "x=$(echo '(a)(b)'); echo \"$x\""
      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "(a)(b)\n"
    end

    test "parentheses inside double quotes inside $()" do
      script = "x=$(echo \"(a)(b)\"); echo \"$x\""
      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "(a)(b)\n"
    end

    test "nested command substitution with quotes" do
      script = "x=$(echo \"$(echo 'inner')\"); echo \"$x\""
      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "inner\n"
    end

    test "deeply nested command substitution" do
      script = "x=$(echo \"$(echo \"$(echo 'deep')\")\"); echo \"$x\""
      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "deep\n"
    end

    test "backticks inside $()" do
      script = "x=$(echo `echo hello`); echo \"$x\""
      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "hello\n"
    end

    test "backslash-paren in single quotes (jq style)" do
      bash = JustBash.new(files: %{"/test.json" => ~S'{"x": 42}'})
      script = "cat /test.json | jq -r '\"value: \\(.x)\"'"
      {result, _} = JustBash.exec(bash, script)
      assert result.stdout == "value: 42\n"
    end

    test "multiple backslash-parens in jq string" do
      bash = JustBash.new(files: %{"/test.json" => ~S'{"a": 1, "b": 2}'})
      script = "cat /test.json | jq -r '\"a=\\(.a), b=\\(.b)\"'"
      {result, _} = JustBash.exec(bash, script)
      assert result.stdout == "a=1, b=2\n"
    end
  end

  describe "multiline content in command substitution" do
    test "multiline echo" do
      script = """
      x=$(echo "line1
      line2")
      echo "$x"
      """

      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "line1\nline2\n"
    end

    test "multiline heredoc in command substitution" do
      script = """
      x=$(cat << 'EOF'
      line1
      line2
      EOF
      )
      echo "$x"
      """

      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "line1\nline2\n"
    end

    test "multiline single-quoted content with special chars" do
      script = """
      x=$(echo 'line with (parens)
      and "quotes"
      and $vars')
      echo "$x"
      """

      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout =~ "line with (parens)"
      assert result.stdout =~ "and \"quotes\""
      assert result.stdout =~ "and $vars"
    end
  end

  describe "command substitution inside various contexts" do
    @tag :skip
    @tag :known_limitation
    test "in array assignment" do
      # Known limitation: array assignment from command substitution not fully supported
      script = """
      arr=($(echo "a b c"))
      echo "${arr[1]}"
      """

      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "b\n"
    end

    test "in for loop word list" do
      script = """
      for x in $(echo "a b c"); do
        echo "$x"
      done
      """

      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "a\nb\nc\n"
    end

    test "in case pattern (value being matched)" do
      script = """
      x=$(echo "hello")
      case "$x" in
        hello) echo "matched" ;;
        *) echo "no match" ;;
      esac
      """

      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "matched\n"
    end

    @tag :skip
    @tag :known_limitation
    test "in arithmetic expression" do
      # Known limitation: command substitution inside arithmetic expansion not fully supported
      script = """
      x=$(($(echo 5) + $(echo 3)))
      echo "$x"
      """

      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "8\n"
    end

    test "in test condition" do
      script = """
      if [ "$(echo yes)" = "yes" ]; then
        echo "matched"
      fi
      """

      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "matched\n"
    end

    test "in parameter expansion default" do
      script = """
      unset x
      echo "${x:-$(echo default)}"
      """

      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "default\n"
    end
  end

  describe "special characters inside command substitution" do
    test "semicolons in single quotes" do
      script = "x=$(echo 'a;b;c'); echo \"$x\""
      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "a;b;c\n"
    end

    test "pipes in single quotes" do
      script = "x=$(echo 'a|b|c'); echo \"$x\""
      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "a|b|c\n"
    end

    test "ampersands in single quotes" do
      script = "x=$(echo 'a&&b'); echo \"$x\""
      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "a&&b\n"
    end

    test "redirects in single quotes" do
      script = "x=$(echo 'a>b<c'); echo \"$x\""
      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "a>b<c\n"
    end

    test "braces in single quotes" do
      script = "x=$(echo '{a,b,c}'); echo \"$x\""
      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "{a,b,c}\n"
    end

    test "brackets in single quotes" do
      script = "x=$(echo '[a-z]'); echo \"$x\""
      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "[a-z]\n"
    end

    test "dollar signs in single quotes" do
      script = "x=$(echo '$HOME'); echo \"$x\""
      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "$HOME\n"
    end

    test "backslashes in single quotes" do
      script = "x=$(echo 'a\\b\\c'); echo \"$x\""
      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "a\\b\\c\n"
    end

    test "newlines in single quotes" do
      script = "x=$(echo 'a\nb'); echo \"$x\""
      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "a\nb\n"
    end
  end

  describe "complex pipeline patterns" do
    test "multiple pipes with quotes" do
      bash = JustBash.new(files: %{"/test.txt" => "hello world\nfoo bar"})
      script = "cat /test.txt | grep \"hello\" | sed 's/hello/hi/'"
      {result, _} = JustBash.exec(bash, script)
      assert result.stdout == "hi world\n"
    end

    test "command substitution with pipe inside double quotes" do
      bash = JustBash.new(files: %{"/test.txt" => "hello"})
      script = "echo \"result: $(cat /test.txt | tr 'a-z' 'A-Z')\""
      {result, _} = JustBash.exec(bash, script)
      assert result.stdout == "result: HELLO\n"
    end

    test "nested command substitution with pipes" do
      script = "x=$(echo $(echo hello | tr 'h' 'H') | tr 'e' 'E'); echo \"$x\""
      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "HEllo\n"
    end
  end

  describe "grep patterns with special regex chars" do
    test "grep with regex metacharacters in pattern" do
      bash = JustBash.new(files: %{"/test.txt" => "foo.bar\nfoo-bar"})
      script = "grep 'foo\\.bar' /test.txt"
      {result, _} = JustBash.exec(bash, script)
      assert result.stdout == "foo.bar\n"
    end

    test "grep with brackets in pattern" do
      bash = JustBash.new(files: %{"/test.txt" => "cat\ncar\ncap"})
      script = "grep 'ca[rt]' /test.txt"
      {result, _} = JustBash.exec(bash, script)
      assert result.stdout == "cat\ncar\n"
    end

    test "grep pattern stored in variable" do
      bash = JustBash.new(files: %{"/test.txt" => "hello world"})
      script = """
      pattern='hello'
      grep "$pattern" /test.txt
      """

      {result, _} = JustBash.exec(bash, script)
      assert result.stdout == "hello world\n"
    end
  end

  describe "sed patterns with special chars" do
    test "sed with forward slashes in pattern" do
      bash = JustBash.new(files: %{"/test.txt" => "/path/to/file"})
      # Using different delimiter
      script = "sed 's|/path|/newpath|' /test.txt"
      {result, _} = JustBash.exec(bash, script)
      assert result.stdout == "/newpath/to/file\n"
    end

    test "sed with ampersand in replacement" do
      bash = JustBash.new(files: %{"/test.txt" => "hello"})
      script = "sed 's/hello/[&]/' /test.txt"
      {result, _} = JustBash.exec(bash, script)
      assert result.stdout == "[hello]\n"
    end

    test "sed with capture groups" do
      bash = JustBash.new(files: %{"/test.txt" => "hello world"})
      script = "sed 's/\\(hello\\) \\(world\\)/\\2 \\1/' /test.txt"
      {result, _} = JustBash.exec(bash, script)
      assert result.stdout == "world hello\n"
    end
  end

  describe "jq complex patterns" do
    test "jq with multiple select conditions" do
      bash =
        JustBash.new(
          files: %{
            "/test.json" => ~S'[{"a":1,"b":2},{"a":2,"b":3},{"a":1,"b":4}]'
          }
        )

      script = "cat /test.json | jq '.[] | select(.a == 1 and .b > 2)'"
      {result, _} = JustBash.exec(bash, script)
      assert result.stdout =~ "\"b\": 4"
    end

    test "jq with object construction" do
      bash = JustBash.new(files: %{"/test.json" => ~S'{"name":"alice","age":30}'})
      script = "cat /test.json | jq '{user: .name, years: .age}'"
      {result, _} = JustBash.exec(bash, script)
      assert result.stdout =~ "\"user\": \"alice\""
      assert result.stdout =~ "\"years\": 30"
    end

    test "jq with array slicing" do
      bash = JustBash.new(files: %{"/test.json" => ~S'[1,2,3,4,5]'})
      script = "cat /test.json | jq '.[1:3]'"
      {result, _} = JustBash.exec(bash, script)
      assert result.stdout =~ "2"
      assert result.stdout =~ "3"
    end

    test "jq with conditional" do
      bash = JustBash.new(files: %{"/test.json" => ~S'{"x": 5}'})
      script = "cat /test.json | jq 'if .x > 3 then \"big\" else \"small\" end'"
      {result, _} = JustBash.exec(bash, script)
      assert result.stdout =~ "big"
    end

    @tag :skip
    @tag :known_limitation
    test "jq with try-catch" do
      # Known limitation: jq try-catch not implemented
      bash = JustBash.new(files: %{"/test.json" => ~S'{"a": 1}'})
      script = "cat /test.json | jq 'try .b.c catch \"not found\"'"
      {result, _} = JustBash.exec(bash, script)
      assert result.stdout =~ "not found"
    end
  end

  describe "variable expansion edge cases" do
    test "variable in single quotes is literal" do
      script = """
      x=hello
      echo '$x'
      """

      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "$x\n"
    end

    test "variable in double quotes is expanded" do
      script = """
      x=hello
      echo "$x"
      """

      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "hello\n"
    end

    test "escaped dollar in double quotes" do
      script = """
      x=hello
      echo "\\$x is $x"
      """

      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "$x is hello\n"
    end

    test "variable concatenation with quotes" do
      # Mixed quoted/unquoted parts: "$prefix" + _ + "$suffix"
      script = """
      prefix=hello
      suffix=world
      echo "$prefix"_"$suffix"
      """

      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "hello_world\n"
    end

    test "empty variable in quotes" do
      script = """
      unset x
      echo "[$x]"
      """

      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.stdout == "[]\n"
    end
  end
end
