defmodule JustBash.BashComparison.GrepTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "grep basic matching" do
    test "basic match" do
      compare_bash("echo -e 'hello\\nworld' | grep 'hello'")
    end

    test "no match returns exit 1" do
      compare_bash("echo 'hello' | grep 'xyz'; echo $?")
    end

    test "multiple matching lines" do
      compare_bash("echo -e 'apple\\nbanana\\napricot' | grep 'a'")
    end

    test "grep from stdin" do
      compare_bash("echo 'hello world' | grep 'ell'")
    end
  end

  describe "grep flags" do
    test "grep -n line numbers" do
      compare_bash("echo -e 'a\\nb\\nc' | grep -n 'b'")
    end

    test "grep -i case insensitive" do
      compare_bash("echo -e 'Hello\\nHELLO\\nhello' | grep -i 'hello'")
    end

    test "grep -v inverted match" do
      compare_bash("echo -e 'a\\nb\\nc' | grep -v 'b'")
    end

    test "grep -c count" do
      compare_bash("echo -e 'a\\nb\\na' | grep -c 'a'")
    end

    test "grep -w word match" do
      compare_bash("echo -e 'foo\\nfoobar\\nbar foo baz' | grep -w 'foo'")
    end

    test "grep -F fixed string" do
      compare_bash("echo 'test.*pattern' | grep -F '.*'")
    end

    test "grep -q quiet mode success" do
      compare_bash("echo 'test' | grep -q 'test' && echo 'found'")
    end

    test "grep -q quiet mode failure" do
      compare_bash("echo 'test' | grep -q 'xyz' || echo 'not found'")
    end

    test "grep -E extended regex alternation" do
      compare_bash("echo -e 'foo\\nbar\\nbaz' | grep -E 'foo|bar'")
    end

    test "grep -E extended regex plus" do
      compare_bash("echo -e 'ab\\naab\\naaab' | grep -E 'a+b'")
    end

    test "grep -o only matching" do
      compare_bash("echo 'hello world' | grep -o 'wor'")
    end
  end

  describe "grep patterns and anchors" do
    test "caret anchor start of line" do
      compare_bash("echo -e 'hello\\nworld\\nhello world' | grep '^hello'")
    end

    test "dollar anchor end of line" do
      compare_bash("echo -e 'hello\\nworld\\nhello world' | grep 'world$'")
    end

    test "dot matches any char" do
      compare_bash("echo -e 'abc\\naXc\\na c' | grep 'a.c'")
    end

    test "character class digits" do
      compare_bash("echo -e 'abc\\n123\\na1b' | grep '[0-9]'")
    end

    test "character class letters" do
      compare_bash("echo -e '123\\nabc\\n456' | grep '[a-z]'")
    end

    test "negated character class" do
      compare_bash("echo -e 'abc\\n123\\na1b' | grep '[^0-9]'")
    end

    test "star quantifier" do
      compare_bash("echo -e 'ac\\nabc\\nabbc' | grep 'ab*c'")
    end

    test "escape special character" do
      compare_bash("echo -e 'a.b\\naxb' | grep 'a\\.b'")
    end
  end

  describe "grep edge cases" do
    test "empty pattern matches all" do
      compare_bash("echo -e 'a\\nb' | grep ''")
    end

    test "empty input" do
      compare_bash("echo -n '' | grep 'a'; echo $?")
    end

    test "special chars in input" do
      compare_bash("echo 'hello\$world' | grep 'hello'")
    end

    test "grep with pipe in pattern using -E" do
      compare_bash("echo -e 'cat\\ndog\\nbird' | grep -E 'cat|dog'")
    end
  end

  describe "grep combined flags" do
    test "grep -in case insensitive with line numbers" do
      compare_bash("echo -e 'Hello\\nworld\\nHELLO' | grep -in 'hello'")
    end

    test "grep -iv inverted case insensitive" do
      compare_bash("echo -e 'Hello\\nworld\\nHELLO' | grep -iv 'hello'")
    end

    test "grep -cv count inverted" do
      compare_bash("echo -e 'a\\nb\\na\\nc' | grep -cv 'a'")
    end
  end

  describe "grep recursive" do
    test "grep -r searches directories recursively" do
      bash =
        JustBash.new(
          files: %{
            "/data/a.txt" => "hello world\n",
            "/data/b.txt" => "goodbye world\n",
            "/data/subdir/c.txt" => "hello again\n"
          }
        )

      {result, _} = JustBash.exec(bash, "grep -r 'hello' /data")
      assert result.exit_code == 0
      assert result.stdout =~ "/data/a.txt"
      assert result.stdout =~ "/data/subdir/c.txt"
      assert result.stdout =~ "hello world"
      assert result.stdout =~ "hello again"
      refute result.stdout =~ "goodbye"
    end

    test "grep -r with no matches returns exit 1" do
      bash = JustBash.new(files: %{"/data/a.txt" => "hello\n"})
      {result, _} = JustBash.exec(bash, "grep -r 'xyz' /data")
      assert result.exit_code == 1
    end

    test "grep -r combined with other flags" do
      bash =
        JustBash.new(
          files: %{
            "/data/a.txt" => "Hello World\n",
            "/data/b.txt" => "hello world\n"
          }
        )

      {result, _} = JustBash.exec(bash, "grep -ri 'hello' /data")
      assert result.exit_code == 0
      assert result.stdout =~ "/data/a.txt"
      assert result.stdout =~ "/data/b.txt"
    end

    test "grep -R is same as -r" do
      bash = JustBash.new(files: %{"/data/a.txt" => "hello\n"})
      {result, _} = JustBash.exec(bash, "grep -R 'hello' /data")
      assert result.exit_code == 0
      assert result.stdout =~ "hello"
    end

    test "grep -r on file works like regular grep" do
      bash = JustBash.new(files: %{"/data/a.txt" => "hello world\n"})
      {result, _} = JustBash.exec(bash, "grep -r 'hello' /data/a.txt")
      assert result.exit_code == 0
      assert result.stdout =~ "hello"
    end

    test "grep -rl lists only matching files" do
      bash =
        JustBash.new(
          files: %{
            "/data/a.txt" => "hello\n",
            "/data/b.txt" => "world\n",
            "/data/c.txt" => "hello world\n"
          }
        )

      {result, _} = JustBash.exec(bash, "grep -rl 'hello' /data")
      assert result.exit_code == 0
      assert result.stdout =~ "/data/a.txt"
      assert result.stdout =~ "/data/c.txt"
      refute result.stdout =~ "/data/b.txt"
    end
  end
end
