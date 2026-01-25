defmodule JustBash.BashComparison.WcTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "wc basic usage" do
    test "count lines words bytes from stdin" do
      compare_bash("echo 'hello world' | wc")
    end

    test "count single line" do
      compare_bash("echo 'hello' | wc")
    end

    test "count multiple lines" do
      compare_bash("echo -e 'a\\nb\\nc' | wc")
    end
  end

  describe "wc individual flags" do
    test "wc -l line count only" do
      compare_bash("echo -e 'a\\nb\\nc' | wc -l")
    end

    test "wc -w word count only" do
      compare_bash("echo 'one two three four' | wc -w")
    end

    test "wc -c byte count only" do
      compare_bash("echo 'hello' | wc -c")
    end

    test "wc -l single line" do
      compare_bash("echo 'hello world' | wc -l")
    end

    test "wc -w single word" do
      compare_bash("echo 'hello' | wc -w")
    end
  end

  describe "wc edge cases" do
    test "empty input" do
      compare_bash("echo -n '' | wc")
    end

    test "empty input line count" do
      compare_bash("echo -n '' | wc -l")
    end

    test "only whitespace" do
      compare_bash("echo '   ' | wc -w")
    end

    test "multiple spaces between words" do
      compare_bash("echo 'a    b    c' | wc -w")
    end

    test "tabs as separators" do
      compare_bash("printf 'a\\tb\\tc' | wc -w")
    end

    test "newline only" do
      compare_bash("echo '' | wc -l")
    end

    test "no trailing newline" do
      compare_bash("printf 'hello' | wc -l")
    end
  end

  describe "wc with multiline input" do
    test "count lines in multiline" do
      compare_bash("echo -e 'line1\\nline2\\nline3' | wc -l")
    end

    test "count words across lines" do
      compare_bash("echo -e 'one two\\nthree four\\nfive' | wc -w")
    end

    test "count bytes in multiline" do
      compare_bash("echo -e 'ab\\ncd' | wc -c")
    end
  end

  describe "wc pipeline combinations" do
    test "wc in middle of pipeline" do
      compare_bash("echo -e 'a\\nb\\nc' | wc -l | tr -d ' '")
    end

    test "grep then wc" do
      compare_bash("echo -e 'apple\\nbanana\\napricot' | grep 'a' | wc -l")
    end

    test "head then wc" do
      compare_bash("echo -e 'a\\nb\\nc\\nd\\ne' | head -3 | wc -l")
    end
  end
end
