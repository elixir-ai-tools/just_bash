defmodule JustBash.BashComparison.SedTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

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

    test "backreference simple" do
      compare_bash("echo 'foo' | sed 's/\\(foo\\)/\\1bar/'")
    end

    test "backreference with multiple groups" do
      compare_bash("echo 'hello world' | sed 's/\\(.*\\) \\(.*\\)/\\2 \\1/'")
    end

    test "backreference in replacement" do
      compare_bash("echo 'test123' | sed 's/\\([a-z]*\\)\\([0-9]*\\)/[\\1]-[\\2]/'")
    end

    test "nth occurrence substitution" do
      compare_bash("echo 'xxx' | sed 's/x/y/2'")
    end

    test "nth occurrence with larger n" do
      compare_bash("echo 'aaaaa' | sed 's/a/b/3'")
    end

    test "regex address range" do
      compare_bash("echo -e 'start\\nfoo\\nbar\\nend\\nbaz' | sed -n '/start/,/end/p'")
    end

    test "regex address range with substitution" do
      compare_bash("echo -e 'begin\\nx\\ny\\nfinish\\nz' | sed '/begin/,/finish/s/x/X/g'")
    end

    test "append command" do
      # BSD sed (macOS) requires $'...' ANSI-C quoting with newline after backslash
      compare_bash("echo -e 'a\\nb\\nc' | sed $'2a\\\\\\nappended text'")
    end

    test "insert command" do
      # BSD sed (macOS) requires $'...' ANSI-C quoting with newline after backslash
      compare_bash("echo -e 'a\\nb\\nc' | sed $'2i\\\\\\ninserted text'")
    end

    test "delete with address range" do
      compare_bash("echo -e 'a\\nb\\nc\\nd\\ne' | sed '2,4d'")
    end

    test "delete with regex" do
      compare_bash("echo -e 'foo\\nbar\\nbaz' | sed '/ba/d'")
    end

    test "change command" do
      # BSD sed (macOS) requires $'...' ANSI-C quoting with newline after backslash
      compare_bash("echo -e 'a\\nb\\nc' | sed $'2c\\\\\\nchanged line'")
    end

    test "multiple commands with semicolon" do
      compare_bash("echo 'abc' | sed 's/a/A/; s/c/C/'")
    end

    test "numbered substitution with ampersand" do
      compare_bash("echo 'xxx' | sed 's/x/(&)/2'")
    end

    test "empty regex uses last regex" do
      compare_bash("echo 'hello' | sed 's/l/L/; s//R/'")
    end

    test "substitution with delimiter change" do
      compare_bash("echo '/path/to/file' | sed 's#/path#/new#'")
    end

    test "multiple line addresses" do
      compare_bash("echo -e 'a\\nb\\nc\\nd' | sed -n '1p; 3p'")
    end

    test "negated address" do
      compare_bash("echo -e 'a\\nb\\nc' | sed -n '/b/!p'")
    end

    test "last line address" do
      compare_bash("echo -e 'a\\nb\\nc' | sed -n '$p'")
    end

    test "first line address" do
      compare_bash("echo -e 'a\\nb\\nc' | sed -n '1p'")
    end
  end
end
