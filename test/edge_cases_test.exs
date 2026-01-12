defmodule JustBash.EdgeCasesTest do
  use ExUnit.Case, async: true

  describe "empty input handling" do
    test "cat with empty file" do
      bash = JustBash.new(files: %{"/empty.txt" => ""})
      {result, _} = JustBash.exec(bash, "cat /empty.txt")
      assert result.stdout == ""
      assert result.exit_code == 0
    end

    test "head with empty file" do
      bash = JustBash.new(files: %{"/empty.txt" => ""})
      {result, _} = JustBash.exec(bash, "head /empty.txt")
      assert result.exit_code == 0
    end

    test "tail with empty file" do
      bash = JustBash.new(files: %{"/empty.txt" => ""})
      {result, _} = JustBash.exec(bash, "tail /empty.txt")
      assert result.stdout == ""
      assert result.exit_code == 0
    end

    test "grep with empty file" do
      bash = JustBash.new(files: %{"/empty.txt" => ""})
      {result, _} = JustBash.exec(bash, "grep pattern /empty.txt")
      assert result.stdout == ""
      assert result.exit_code == 1
    end

    test "sort with empty file" do
      bash = JustBash.new(files: %{"/empty.txt" => ""})
      {result, _} = JustBash.exec(bash, "sort /empty.txt")
      assert result.stdout == ""
      assert result.exit_code == 0
    end

    test "uniq with empty file" do
      bash = JustBash.new(files: %{"/empty.txt" => ""})
      {result, _} = JustBash.exec(bash, "uniq /empty.txt")
      assert result.stdout == ""
      assert result.exit_code == 0
    end

    test "wc with empty file" do
      bash = JustBash.new(files: %{"/empty.txt" => ""})
      {result, _} = JustBash.exec(bash, "wc /empty.txt")
      assert result.stdout =~ "0"
      assert result.exit_code == 0
    end

    test "sed with empty file" do
      bash = JustBash.new(files: %{"/empty.txt" => ""})
      {result, _} = JustBash.exec(bash, "sed 's/a/b/' /empty.txt")
      assert result.stdout == ""
      assert result.exit_code == 0
    end

    test "awk with empty file" do
      bash = JustBash.new(files: %{"/empty.txt" => ""})
      {result, _} = JustBash.exec(bash, "awk '{print}' /empty.txt")
      assert result.stdout == ""
      assert result.exit_code == 0
    end

    test "cut with empty file" do
      bash = JustBash.new(files: %{"/empty.txt" => ""})
      {result, _} = JustBash.exec(bash, "cut -f1 /empty.txt")
      assert result.stdout == ""
      assert result.exit_code == 0
    end

    test "tr with empty stdin" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo -n '' | tr 'a' 'b'")
      assert result.stdout == ""
      assert result.exit_code == 0
    end

    test "rev with empty file" do
      bash = JustBash.new(files: %{"/empty.txt" => ""})
      {result, _} = JustBash.exec(bash, "rev /empty.txt")
      assert result.stdout == ""
      assert result.exit_code == 0
    end

    test "tac with empty file" do
      bash = JustBash.new(files: %{"/empty.txt" => ""})
      {result, _} = JustBash.exec(bash, "tac /empty.txt")
      assert result.stdout == ""
      assert result.exit_code == 0
    end
  end

  describe "single line without newline" do
    test "cat preserves content without trailing newline" do
      bash = JustBash.new(files: %{"/no_newline.txt" => "content"})
      {result, _} = JustBash.exec(bash, "cat /no_newline.txt")
      assert result.stdout == "content"
    end

    test "head with single line no newline" do
      bash = JustBash.new(files: %{"/no_newline.txt" => "single line"})
      {result, _} = JustBash.exec(bash, "head -1 /no_newline.txt")
      assert result.stdout == "single line\n"
    end

    test "tail with single line no newline" do
      bash = JustBash.new(files: %{"/no_newline.txt" => "single line"})
      {result, _} = JustBash.exec(bash, "tail -1 /no_newline.txt")
      assert result.stdout == "single line\n"
    end

    test "grep matches line without newline" do
      bash = JustBash.new(files: %{"/no_newline.txt" => "match this"})
      {result, _} = JustBash.exec(bash, "grep match /no_newline.txt")
      assert result.stdout == "match this\n"
    end

    test "wc counts single line without newline" do
      bash = JustBash.new(files: %{"/no_newline.txt" => "one two three"})
      {result, _} = JustBash.exec(bash, "wc -w /no_newline.txt")
      assert result.stdout =~ "3"
    end
  end

  describe "very long lines" do
    test "cat handles long line" do
      long_line = String.duplicate("a", 10000)
      bash = JustBash.new(files: %{"/long.txt" => long_line})
      {result, _} = JustBash.exec(bash, "cat /long.txt")
      assert result.stdout == long_line
    end

    test "grep handles long line" do
      long_line = String.duplicate("a", 10000) <> "needle" <> String.duplicate("b", 10000)
      bash = JustBash.new(files: %{"/long.txt" => long_line <> "\n"})
      {result, _} = JustBash.exec(bash, "grep needle /long.txt")
      assert result.stdout == long_line <> "\n"
    end

    test "sed handles long line" do
      long_line = String.duplicate("x", 5000)
      bash = JustBash.new(files: %{"/long.txt" => long_line <> "\n"})
      {result, _} = JustBash.exec(bash, "sed 's/x/y/g' /long.txt")
      assert result.stdout == String.duplicate("y", 5000) <> "\n"
    end

    test "wc counts long line correctly" do
      long_line = String.duplicate("word ", 1000)
      bash = JustBash.new(files: %{"/long.txt" => long_line <> "\n"})
      {result, _} = JustBash.exec(bash, "wc -w /long.txt")
      assert result.stdout =~ "1000"
    end

    test "cut handles long line" do
      long_line = Enum.map_join(1..100, ":", &to_string/1)
      bash = JustBash.new(files: %{"/long.txt" => long_line <> "\n"})
      {result, _} = JustBash.exec(bash, "cut -d: -f50 /long.txt")
      assert result.stdout == "50\n"
    end
  end

  describe "special characters in content" do
    test "cat with special characters" do
      content = "hello\tworld\nfoo\rbar"
      bash = JustBash.new(files: %{"/special.txt" => content})
      {result, _} = JustBash.exec(bash, "cat /special.txt")
      assert result.stdout == content
    end

    test "grep with literal dot in pattern" do
      bash = JustBash.new(files: %{"/file.txt" => "a.b\naxb\n"})
      {result, _} = JustBash.exec(bash, "grep 'a.b' /file.txt")
      assert result.stdout =~ "a.b"
    end

    test "sed with special characters in replacement" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'hello' | sed 's/hello/a\\tb/'")
      assert result.stdout == "a\tb\n"
    end

    test "echo with backslash" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo -e 'back\\\\slash'")
      assert result.stdout == "back\\slash\n"
    end

    test "awk with tabs as field separator" do
      bash = JustBash.new(files: %{"/tabs.txt" => "a\tb\tc\n"})
      {result, _} = JustBash.exec(bash, "awk '{print $2}' /tabs.txt")
      assert result.stdout == "b\n"
    end
  end

  describe "unicode content" do
    test "cat with unicode" do
      bash = JustBash.new(files: %{"/unicode.txt" => "héllo wörld\n"})
      {result, _} = JustBash.exec(bash, "cat /unicode.txt")
      assert result.stdout == "héllo wörld\n"
    end

    test "wc counts unicode file" do
      bash = JustBash.new(files: %{"/unicode.txt" => "héllo\n"})
      {result, _} = JustBash.exec(bash, "wc -c /unicode.txt")
      assert result.exit_code == 0
    end

    test "rev reverses ASCII string" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'abc' | rev")
      assert result.stdout == "cba\n"
    end

    test "tr with ASCII characters" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'hello' | tr 'aeiou' 'AEIOU'")
      assert result.stdout == "hEllO\n"
    end
  end

  describe "large files" do
    test "head with many lines" do
      lines = Enum.map_join(1..1000, "\n", &to_string/1) <> "\n"
      bash = JustBash.new(files: %{"/many.txt" => lines})
      {result, _} = JustBash.exec(bash, "head -n 5 /many.txt")
      assert result.stdout == "1\n2\n3\n4\n5\n"
    end

    test "tail with many lines" do
      lines = Enum.map_join(1..1000, "\n", &to_string/1) <> "\n"
      bash = JustBash.new(files: %{"/many.txt" => lines})
      {result, _} = JustBash.exec(bash, "tail -n 3 /many.txt")
      assert result.stdout == "998\n999\n1000\n"
    end

    test "sort with many lines" do
      lines = Enum.map_join(1000..1//-1, "\n", &to_string/1) <> "\n"
      bash = JustBash.new(files: %{"/unsorted.txt" => lines})
      {result, _} = JustBash.exec(bash, "sort -n /unsorted.txt | head -5")
      assert result.stdout == "1\n2\n3\n4\n5\n"
    end

    test "grep with many lines" do
      lines = Enum.map_join(1..1000, "\n", fn n -> "line #{n}" end) <> "\n"
      bash = JustBash.new(files: %{"/many.txt" => lines})
      {result, _} = JustBash.exec(bash, "grep 'line 500' /many.txt")
      assert result.stdout == "line 500\n"
    end

    test "uniq with many consecutive duplicates" do
      lines = String.duplicate("same\n", 100)
      bash = JustBash.new(files: %{"/dups.txt" => lines})
      {result, _} = JustBash.exec(bash, "uniq /dups.txt")
      assert result.stdout == "same\n"
    end

    test "uniq -c with many duplicates" do
      lines = String.duplicate("same\n", 100)
      bash = JustBash.new(files: %{"/dups.txt" => lines})
      {result, _} = JustBash.exec(bash, "uniq -c /dups.txt")
      assert result.stdout =~ "100"
    end
  end

  describe "boundary conditions for head/tail" do
    test "tail -n 0 outputs nothing" do
      bash = JustBash.new(files: %{"/file.txt" => "line1\nline2\n"})
      {result, _} = JustBash.exec(bash, "tail -n 0 /file.txt")
      assert result.stdout == ""
    end

    test "head requests more lines than file has" do
      bash = JustBash.new(files: %{"/file.txt" => "line1\nline2\n"})
      {result, _} = JustBash.exec(bash, "head -n 100 /file.txt")
      assert result.exit_code == 0
    end

    test "tail requests more lines than file has" do
      bash = JustBash.new(files: %{"/file.txt" => "line1\nline2\n"})
      {result, _} = JustBash.exec(bash, "tail -n 100 /file.txt")
      assert result.stdout == "line1\nline2\n"
    end
  end

  describe "sed edge cases" do
    test "sed with empty pattern" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'hello' | sed 's//X/g'")
      assert result.exit_code == 0
    end

    test "sed with pattern at start of line" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'hello world' | sed 's/^hello/hi/'")
      assert result.stdout == "hi world\n"
    end

    test "sed with pattern at end of line" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'hello world' | sed 's/world$/universe/'")
      assert result.stdout == "hello universe\n"
    end

    test "sed with entire line match" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'hello' | sed 's/^.*$/replaced/'")
      assert result.stdout == "replaced\n"
    end

    test "sed with basic substitution" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'hello world' | sed 's/hello/[hello]/'")
      assert result.stdout == "[hello] world\n"
    end

    test "sed on line with only whitespace" do
      bash = JustBash.new(files: %{"/file.txt" => "   \n"})
      {result, _} = JustBash.exec(bash, "sed 's/ /X/g' /file.txt")
      assert result.stdout == "XXX\n"
    end
  end

  describe "awk edge cases" do
    test "awk with more fields than data" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'a b' | awk '{print $5}'")
      assert result.stdout == "\n"
    end

    test "awk prints $0" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'hello' | awk '{print $0}'")
      assert result.stdout == "hello\n"
    end

    test "awk NF on empty line" do
      bash = JustBash.new(files: %{"/file.txt" => "\n"})
      {result, _} = JustBash.exec(bash, "awk '{print NF}' /file.txt")
      assert result.stdout == "0\n"
    end

    test "awk with multiple spaces between fields" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'a    b    c' | awk '{print $2}'")
      assert result.stdout == "b\n"
    end

    test "awk BEGIN without input file" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo '' | awk 'BEGIN{print \"start\"}'")
      assert result.stdout == "start\n"
    end

    test "awk END block runs even with empty input" do
      bash = JustBash.new(files: %{"/empty.txt" => ""})
      {result, _} = JustBash.exec(bash, "awk 'END{print \"done\"}' /empty.txt")
      assert result.stdout == "done\n"
    end
  end

  describe "grep edge cases" do
    test "grep -v with no matches returns all lines" do
      bash = JustBash.new(files: %{"/file.txt" => "apple\nbanana\n"})
      {result, _} = JustBash.exec(bash, "grep -v xyz /file.txt")
      assert result.stdout =~ "apple"
      assert result.stdout =~ "banana"
    end

    test "grep with specific pattern" do
      bash = JustBash.new(files: %{"/file.txt" => "line1\nline2\ntest\n"})
      {result, _} = JustBash.exec(bash, "grep line /file.txt")
      assert result.stdout == "line1\nline2\n"
    end
  end

  describe "sort edge cases" do
    test "sort with single line" do
      bash = JustBash.new(files: %{"/file.txt" => "only\n"})
      {result, _} = JustBash.exec(bash, "sort /file.txt")
      assert result.stdout == "only\n"
    end

    test "sort already sorted" do
      bash = JustBash.new(files: %{"/file.txt" => "a\nb\nc\n"})
      {result, _} = JustBash.exec(bash, "sort /file.txt")
      assert result.stdout == "a\nb\nc\n"
    end

    test "sort -n with negative numbers" do
      bash = JustBash.new(files: %{"/file.txt" => "-5\n10\n-20\n0\n"})
      {result, _} = JustBash.exec(bash, "sort -n /file.txt")
      assert result.stdout == "-20\n-5\n0\n10\n"
    end

    test "sort -n with mixed content" do
      bash = JustBash.new(files: %{"/file.txt" => "10\nabc\n5\n"})
      {result, _} = JustBash.exec(bash, "sort -n /file.txt")
      assert result.exit_code == 0
    end

    test "sort -u with all duplicates" do
      bash = JustBash.new(files: %{"/file.txt" => "a\na\na\na\n"})
      {result, _} = JustBash.exec(bash, "sort -u /file.txt")
      assert result.stdout == "a\n"
    end
  end

  describe "cut edge cases" do
    test "cut field beyond available" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'a:b:c' | cut -d: -f10")
      assert result.exit_code == 0
    end

    test "cut with delimiter not in input" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'no delimiter' | cut -d: -f1")
      assert result.stdout == "no delimiter\n"
    end

    test "cut single character" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'x' | cut -c1")
      assert result.stdout == "x\n"
    end

    test "cut first field" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'a:b:c' | cut -d: -f1")
      assert result.stdout == "a\n"
    end

    test "cut middle field" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'a:b:c' | cut -d: -f2")
      assert result.stdout == "b\n"
    end
  end

  describe "tr edge cases" do
    test "tr with same source and dest" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'hello' | tr 'a' 'a'")
      assert result.stdout == "hello\n"
    end

    test "tr delete all characters" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'aaa' | tr -d 'a'")
      assert result.stdout == "\n"
    end

    test "tr with range at boundary" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'az' | tr 'a-z' 'A-Z'")
      assert result.stdout == "AZ\n"
    end
  end

  describe "file operation edge cases" do
    test "ls empty directory" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "mkdir /emptydir")
      {result, _} = JustBash.exec(bash, "ls /emptydir")
      assert result.stdout == ""
      assert result.exit_code == 0
    end

    test "cp file to different location" do
      bash = JustBash.new(files: %{"/file.txt" => "content"})
      {result, bash} = JustBash.exec(bash, "cp /file.txt /file2.txt")
      assert result.exit_code == 0
      {result2, _} = JustBash.exec(bash, "cat /file2.txt")
      assert result2.stdout == "content"
    end

    test "mv to same location" do
      bash = JustBash.new(files: %{"/file.txt" => "content"})
      {result, _} = JustBash.exec(bash, "mv /file.txt /file.txt")
      assert result.exit_code == 0
    end

    test "rm with multiple nonexistent files" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "rm /a /b /c 2>&1")
      assert result.exit_code == 1
    end

    test "mkdir existing directory without -p" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "mkdir /testdir")
      {result, _} = JustBash.exec(bash, "mkdir /testdir")
      assert result.exit_code == 1
    end

    test "touch creates new file" do
      bash = JustBash.new()
      {result, bash} = JustBash.exec(bash, "touch /newfile.txt")
      assert result.exit_code == 0
      {result2, _} = JustBash.exec(bash, "[ -f /newfile.txt ] && echo yes")
      assert result2.stdout == "yes\n"
    end
  end

  describe "path edge cases" do
    test "cd to root" do
      bash = JustBash.new()
      {result, bash} = JustBash.exec(bash, "cd /")
      assert result.exit_code == 0
      assert bash.cwd == "/"
    end

    test "dirname of root" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "dirname /")
      assert result.stdout == "/\n"
    end

    test "basename of file" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "basename /path/to/file.txt")
      assert result.stdout == "file.txt\n"
    end

    test "cd with multiple slashes" do
      bash = JustBash.new()
      {result, _bash} = JustBash.exec(bash, "cd //tmp//")
      assert result.exit_code == 0
    end

    test "ls with trailing slash" do
      bash = JustBash.new(files: %{"/dir/file.txt" => "content"})
      {result, _} = JustBash.exec(bash, "ls /dir/")
      assert result.stdout =~ "file.txt"
    end
  end

  describe "variable edge cases" do
    test "empty variable in command" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $UNDEFINED")
      assert result.stdout == "\n"
    end

    test "variable with spaces in value" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "VAR='hello world'")
      {result, _} = JustBash.exec(bash, "echo \"$VAR\"")
      assert result.stdout == "hello world\n"
    end

    test "variable with newlines in value" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "VAR=$'line1\\nline2'")
      {result, _} = JustBash.exec(bash, "echo \"$VAR\"")
      assert result.exit_code == 0
    end

    test "variable name with underscore" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "MY_VAR=test")
      {result, _} = JustBash.exec(bash, "echo $MY_VAR")
      assert result.stdout == "test\n"
    end

    test "variable name with numbers" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "VAR123=value")
      {result, _} = JustBash.exec(bash, "echo $VAR123")
      assert result.stdout == "value\n"
    end

    test "arithmetic with undefined variable" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $((UNDEFINED + 1))")
      assert result.stdout == "1\n"
    end
  end

  describe "quoting edge cases" do
    test "empty single quotes" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo ''")
      assert result.stdout == "\n"
    end

    test "empty double quotes" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo \"\"")
      assert result.stdout == "\n"
    end

    test "nested quotes" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo \"it's\"")
      assert result.stdout == "it's\n"
    end

    test "escaped quote in double quotes" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo \"say \\\"hello\\\"\"")
      assert result.stdout == "say \"hello\"\n"
    end

    test "dollar sign in single quotes" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo '$VAR'")
      assert result.stdout == "$VAR\n"
    end
  end
end
